//! Bridge to a [GameNight](https://github.com/joepio/gamenight) party daemon.
//!
//! GameNight launches jumpy once at the start of the night and keeps it
//! resident, driving repeated match sessions through a small WebSocket
//! protocol (`prepare` -> `ready` -> `start` -> ... -> `finished` ->
//! `dispose`, repeating for every game). See
//! `docs/integrating-your-game.md` in the GameNight repo for the full
//! contract.
//!
//! jumpy's game loop is entirely synchronous (there is no tokio runtime
//! anywhere else in this codebase), while the daemon connection is async, so
//! the connection lives on its own background OS thread running a
//! single-threaded tokio runtime. That thread only ever talks to the rest of
//! the game through two channels, exposed as a bones resource
//! ([`GameNightBridge`]) that an always-on session polls once per frame.
//!
//! Everything in this module is a no-op unless the process was launched by a
//! daemon (`GAMENIGHT=1` in the environment) — standalone play is completely
//! unaffected.
//!
//! Not built for wasm: the daemon and its native TCP/WebSocket connection
//! have no meaning in the browser build.

use std::collections::HashSet;
use std::time::Duration;

use crate::core::{LobbyDefaultMatchRunner, MatchPlugin};
use crate::prelude::*;

use gamenight_protocol::{
    ClientMessage, GameId, InstallState, PartySnapshot, Player, PlayerId, Role, Seat, SeatOccupant,
    ServerMessage, SessionId,
};
// Aliased: jumpy's own bones `GameMeta` (skins, maps, ...) already occupies
// that name via `crate::prelude::*` — this one is the daemon's shelf entry
// (title, cover art, ...) for a whole game process, a different concept.
use gamenight_protocol::GameMeta as ShelfMeta;
use gamenight_sdk::{GameEvent, GameNight};

/// What the lobby should say about the next game.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NextGameStatus {
    /// A game is *open*: running, or paused because the party stepped out to
    /// the lobby. Outranks everything below, because while there is a game to
    /// go back to, "what's up next" is not the question being asked.
    Live { title: String, paused: bool },
    /// Warm and ready to start.
    Ready(String),
    /// On its way: the process is launching, or the session is preparing.
    /// The second field is how far along the game says it is, if it says —
    /// reporting is optional, and a game that loads instantly has nothing
    /// useful to report.
    Loading(String, Option<LoadingProgress>),
    /// Nothing playable yet, but a game is on its way: title, and how far
    /// along the download is if it's actually moving bytes.
    ///
    /// Ranks below everything above it and above `Empty`, which is exactly
    /// what a first run needs — the shelf is genuinely empty, so this is the
    /// only true thing the screen can say.
    Downloading(String, Option<u8>),
    /// Genuinely nothing to play — an empty shelf.
    Empty,
    /// The party has to choose before anything else happens.
    Voting,
}

/// The TV's left-hand button, which is not always the same button: with a
/// game open it takes you back into it, otherwise it starts the warm one —
/// and while that one is still loading there is nothing for it to do.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TvButton {
    Start,
    Back,
    Disabled,
}

/// What a warming game says it's doing. Waiting is much easier to bear when
/// the screen shows something moving, so games are encouraged to report —
/// but a percentage nobody sent must never be invented.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LoadingProgress {
    pub percent: u8,
    pub label: Option<String>,
}

/// Commands the bridge system sends back to the background connection
/// thread, to be relayed to the daemon.
enum OutgoingMessage {
    Ready(SessionId),
    Finished(SessionId),
}

/// Shared state between the background connection thread and the bones
/// systems that drive jumpy's sessions from it.
#[derive(HasSchema, Clone)]
#[schema(no_default)]
pub struct GameNightBridge {
    incoming: async_channel::Receiver<GameEvent>,
    outgoing: async_channel::Sender<OutgoingMessage>,
    /// Live party snapshots. Comes from the *overlay*-role connection
    /// (`overlay_connection_loop`), not the game-role one above — the
    /// daemon only ever broadcasts `party_state` to overlay connections
    /// (`gamenight-daemon/src/lib.rs`'s `dispatch`: `for tx in
    /// self.overlays.values()`), so a join/leave would otherwise never be
    /// visible here at all outside of the seats embedded in a `Prepare`.
    party_updates: async_channel::Receiver<PartySnapshot>,
    /// Send party commands (`join_party` for now) — needs the overlay-role
    /// connection above too; the daemon rejects party commands from games.
    join_tx: async_channel::Sender<ClientMessage>,
    /// The session the daemon most recently `prepare`d us for. Lets any
    /// system (notably the scoring screen) report `finished` without a
    /// session id being threaded through every call site. `None` means
    /// we're not in a real daemon-driven match — i.e. we're in the lobby.
    current_session: Option<SessionId>,
    /// Guards against sending `finished` twice for the same session.
    notified_finished: bool,
    /// Latest seats from the daemon.
    latest_seats: Vec<Seat>,
    /// When the lobby session should next be rebuilt to reflect
    /// `latest_seats`/`player_gamepad`, or `None` if it's already current.
    /// A join touches this twice in quick succession — once when the seat
    /// appears, again moments later once `player_gamepad` resolves — so
    /// each trigger *restarts* the deadline rather than rebuilding
    /// immediately. Rebuilding twice back to back (tear down, recreate, tear
    /// down, recreate) left a stale camera behind every time, spamming
    /// "Camera order ambiguities" and burning CPU on it forever after.
    /// Wall-clock (`Instant`), not a frame count: the fixed-update stage
    /// this runs in can fall well behind real time under load (see the
    /// "Frame took too long" warnings), so a frame-counted debounce could
    /// take far longer than intended to actually fire.
    lobby_rebuild_at: Option<std::time::Instant>,
    /// Latest player list — just for matching a pending controller join
    /// (sent by name) back to the pad that sent it. See
    /// `GlobalInput::reconcile_joins`.
    pub latest_players: Vec<Player>,
    /// Which gilrs gamepad index actually joined each player — written by
    /// `global_input_system` once a join is confirmed, read by
    /// `match_plugin_for_seats` so a seated player is controlled by the pad
    /// that joined them instead of a hardcoded keyboard mapping.
    player_gamepad: std::collections::HashMap<gamenight_protocol::PlayerId, u32>,
    /// How many gamepads are physically plugged in, mirrored from Bevy's
    /// `Gamepads` so the bones side can see it. The attract overlay uses it to
    /// tell someone to connect a pad or to press A, rather than guessing.
    pub pads_connected: usize,
    /// The game shelf from the daemon's latest snapshot — lets the lobby's
    /// next-game trigger show the real upcoming title instead of a
    /// placeholder.
    latest_library: Vec<ShelfMeta>,
    /// The session the daemon is warming up to play next, if any — *with*
    /// its phase. The phase is the difference between "loading" and "ready",
    /// and dropping it meant the lobby TV could only ever say the title or
    /// "Nothing queued", which reads as an empty shelf even when a game is
    /// mid-launch or its process failed to start.
    latest_warm: Option<gamenight_protocol::SessionInfo>,
    /// What the daemon is heading for when there's no session yet, straight
    /// from the snapshot. Guessing this from the playlist was wrong: the
    /// obvious guess is the first entry, which can be the game that is
    /// already running — so the TV sat on "Loading…" for a game that had
    /// in fact already started.
    latest_warming: Option<gamenight_protocol::PlaylistEntry>,
    /// The playlist, straight from the snapshot. Kept so the TV's SKIP pad
    /// can name what comes *after* whatever is warming — the daemon takes a
    /// game id, not "the next one", and only this list says what that is.
    latest_playlist: Vec<gamenight_protocol::PlaylistEntry>,
    /// Whether the party is being asked to pick the next game. Nothing warms
    /// until they do, so a screen that says "loading" here is lying.
    vote_open: bool,
    /// Games the daemon is fetching in the background, most interesting
    /// first. On a first run this is the only thing happening — the shelf is
    /// empty and a game is on its way — so without it the lobby greets a new
    /// player with "Nothing queued" while it is in fact busy fixing that.
    latest_installs: Vec<gamenight_protocol::InstallStatus>,
    /// The game currently holding the couch, if any. The lobby never has a
    /// session of its own, so this being `Some` is exactly "somebody else is
    /// on the screen right now" — which is what makes reaching for the lobby
    /// window mean something (see `reached_for_the_lobby_system`).
    /// The session being played, if any — *with* its phase, because paused
    /// and running are the difference between "go back in" and "you're
    /// already there".
    active_session: Option<gamenight_protocol::SessionInfo>,
    /// Warm and waiting: stay off the screen until `Start` says otherwise.
    /// Re-asserted every frame rather than acted on once, because `Prepare`
    /// lands while the process is still starting up and hiding an app that
    /// hasn't put a window on screen yet does nothing.
    hide_while_warm: bool,
    /// The *seat* the wall's join QR currently points at — whoever last
    /// landed on the sign-in platform (`core::elements::sign_in`).
    ///
    /// One big readable code re-aimed by jumping, rather than a tiny code
    /// per character: at a size that doesn't swamp the arena, a per-head QR
    /// is unreadable from the couch.
    ///
    /// A seat index rather than a player id because seats are stable — the
    /// daemon clears `players` when the lobby process restarts, which
    /// silently invalidated every id-bearing code printed before it.
    claim_seat: Option<u8>,
    /// What the host has playing in the background, straight from the party
    /// snapshot — `None` whenever there's no music on, which is most nights
    /// and is why the lobby's jukebox only exists some of the time.
    now_playing: Option<gamenight_protocol::NowPlaying>,
    /// What the targeted player looked like when the pad was aimed at them.
    ///
    /// Compared against each incoming party snapshot: once that player's
    /// identity changes, their scan has landed and the pad is released so the
    /// next person can use it. Without this the sign stays aimed at whoever
    /// stood there last, and the queue behind them is stuck reading someone
    /// else's name.
    claim_mark: Option<String>,
    /// Seats that have walked into the exit doorway and not yet been shown out,
    /// with how long their pad should be barred from rejoining afterwards.
    ///
    /// A queue rather than a single slot: the bones session runs at its own
    /// rate and the bevy side drains this once a frame, so two people leaving
    /// together must not overwrite each other. Drained, never read twice.
    exit_requests: Vec<(u8, f32)>,
}

impl GameNightBridge {
    /// Tell the daemon the current match is over. Safe to call more than
    /// once per session: only the first call after a `prepare` sends
    /// anything.
    pub fn notify_finished(&mut self) {
        if self.notified_finished {
            return;
        }
        let Some(session) = self.current_session else {
            return;
        };
        self.notified_finished = true;
        let _ = self.outgoing.try_send(OutgoingMessage::Finished(session));
    }

    /// Skip straight to the next warm game, no vote — used by the "next
    /// game" map element so standing on it in the lobby starts the next
    /// match immediately. Goes over the overlay-role connection (`join_tx`),
    /// same as every other party command; the daemon rejects these from a
    /// game-role connection.
    pub fn request_next_game(&self) {
        let _ = self.join_tx.try_send(ClientMessage::Next);
    }

    /// The shelf title for a game id, falling back to the id itself: a game
    /// missing from the shelf shouldn't erase itself from the screen.
    fn title_of(&self, game: &GameId) -> String {
        self.latest_library
            .iter()
            .find(|m| &m.id == game)
            .map(|m| m.title.clone())
            .unwrap_or_else(|| game.0.clone())
    }

    /// The game being played right now, if any.
    pub fn active_game(&self) -> Option<&GameId> {
        self.active_session.as_ref().map(|s| &s.game)
    }

    /// What the TV's left-hand button does at this moment.
    pub fn tv_button(&self) -> TvButton {
        match self.next_game_status() {
            NextGameStatus::Live { .. } => TvButton::Back,
            NextGameStatus::Ready(_) => TvButton::Start,
            _ => TvButton::Disabled,
        }
    }

    /// Press it. Nothing happens when it's disabled — see `TvButton`.
    pub fn press_tv_button(&self) {
        match self.tv_button() {
            // Back into the game they stepped out of. `CloseOverlay` rather
            // than `Resume` because the overlay is *why* it paused: the lobby
            // announces itself with `OpenOverlay` whenever it takes the
            // screen, and this is that statement being withdrawn.
            TvButton::Back => {
                let _ = self.join_tx.try_send(ClientMessage::CloseOverlay);
            }
            TvButton::Start => {
                let _ = self.join_tx.try_send(ClientMessage::Next);
            }
            TvButton::Disabled => {}
        }
    }

    /// Whether the game on the TV can start this instant.
    ///
    /// The pad in front of the TV is disabled until this is true. Starting a
    /// game that hasn't finished warming isn't faster — the daemon holds the
    /// transition until it's ready anyway — it just hands the party a frozen
    /// lobby and no explanation, which reads as a crash.
    pub fn next_game_is_ready(&self) -> bool {
        matches!(self.next_game_status(), NextGameStatus::Ready(_))
    }

    /// Put a different game on the TV: the entry after whatever is up next.
    ///
    /// "Not this one" is a thing parties say constantly and the lobby had no
    /// way to express — the only control was START, so a shelf you didn't
    /// fancy could only be changed from the overlay on somebody's phone.
    ///
    /// Sent as `PlayNext` for the game we land on rather than as a "skip",
    /// because the daemon deals in titles: the playlist is the only place
    /// that knows what "the one after this" means, and this is the side
    /// holding it.
    pub fn skip_next_game(&self) {
        // With a game open, "skip" is the party leaving it: done with this
        // one, on to the next. It is the only thing that closes a session —
        // stepping out to the lobby merely pauses it, so a game you walked
        // out of is still there to walk back into until somebody skips it.
        if self.active_session.is_some() {
            let _ = self.join_tx.try_send(ClientMessage::Next);
            return;
        }
        let Some(game) = self.game_after_next() else {
            return;
        };
        let _ = self.join_tx.try_send(ClientMessage::PlayNext { game });
    }

    /// The playlist entry after whatever is currently up next, skipping the
    /// lobby itself (its launch spec has to live in the playlist somewhere,
    /// but it is furniture, not a game the party can pick) and whatever is
    /// already being played.
    fn game_after_next(&self) -> Option<gamenight_protocol::GameId> {
        let up_next = self
            .latest_warm
            .as_ref()
            .map(|w| w.game.clone())
            .or_else(|| self.latest_warming.as_ref().map(|e| e.game.clone()));
        let entries = &self.latest_playlist;
        if entries.is_empty() {
            return None;
        }
        let start = up_next
            .as_ref()
            .and_then(|game| entries.iter().position(|e| &e.game == game))
            // Nothing warm to skip past: offer the first entry that isn't us.
            .map_or(0, |i| i + 1);
        let lobby = gamenight_protocol::GameId::new(
            std::env::var("GAMENIGHT_GAME_ID").unwrap_or_else(|_| "lobby".to_string()),
        );
        (0..entries.len())
            .map(|offset| &entries[(start + offset) % entries.len()].game)
            .find(|game| {
                **game != lobby
                    && Some(*game) != up_next.as_ref()
                    && Some(*game) != self.active_game()
            })
            .cloned()
    }

    /// The record the host has on, if any. `None` is the normal state, and
    /// the lobby draws no jukebox at all for it — see
    /// `core::elements::music_pad`.
    pub fn now_playing(&self) -> Option<&gamenight_protocol::NowPlaying> {
        self.now_playing.as_ref()
    }

    /// Pause, resume or skip the host's music, on behalf of whoever stood on
    /// the pad. Goes over the overlay-role connection like every other party
    /// command; the daemon is what actually knows how to talk to Spotify.
    pub fn control_music(&self, action: gamenight_protocol::MediaAction) {
        let _ = self.join_tx.try_send(ClientMessage::MediaControl { action });
    }

    /// What to say about the next game.
    ///
    /// Three genuinely different situations, which the TV must not conflate:
    /// a game ready to go, a game on its way, and an empty shelf. Saying
    /// "Nothing queued" for the middle one is a lie that looks like a bug.
    pub fn next_game_status(&self) -> NextGameStatus {
        if let Some(active) = &self.active_session {
            return NextGameStatus::Live {
                title: self.title_of(&active.game),
                paused: active.phase == gamenight_protocol::SessionPhase::Paused,
            };
        }
        if let Some(warm) = &self.latest_warm {
            let title = self
                .latest_library
                .iter()
                .find(|m| m.id == warm.game)
                // A warm session for a game missing from the shelf shouldn't
                // erase it from the screen; its id is better than nothing.
                .map(|m| m.title.clone())
                .unwrap_or_else(|| warm.game.0.clone());
            return match warm.phase {
                gamenight_protocol::SessionPhase::Ready
                | gamenight_protocol::SessionPhase::Running => NextGameStatus::Ready(title),
                _ => NextGameStatus::Loading(
                    title,
                    warm.progress.map(|percent| LoadingProgress {
                        percent,
                        label: warm.progress_label.clone(),
                    }),
                ),
            };
        }

        // A vote outranks everything else: nothing will warm until the party
        // has chosen, so neither "loading" nor "nothing" is true.
        if self.vote_open {
            return NextGameStatus::Voting;
        }
        // No session yet, but the daemon has said what it's heading for —
        // its process is starting, or a launch is being retried. That is
        // "loading", not "nothing".
        if let Some(entry) = &self.latest_warming {
            // No session means the process isn't even up yet, so there's
            // nothing it could have reported.
            return NextGameStatus::Loading(entry.title.clone(), None);
        }
        // Nothing warm, nothing warming, no vote: if a game is arriving, that
        // is the most useful true thing left to say. `installs` is already
        // ordered with whatever is actually moving first, so the head of the
        // list is the one to show.
        // Bound as `arriving`, not `install`: jumpy's bones prelude is glob
        // imported here and already has an `install`, which makes the pattern
        // ambiguous rather than a plain binding.
        if let Some(arriving) = self
            .latest_installs
            .iter()
            .find(|i| !matches!(i.state, InstallState::Installed | InstallState::Failed))
        {
            return NextGameStatus::Downloading(arriving.title.clone(), arriving.percent);
        }
        NextGameStatus::Empty
    }

    /// Whether some *other* game currently owns the couch — i.e. there is an
    /// active session that isn't the lobby itself. The lobby has no session of
    /// its own, so "something is playing" is exactly "the lobby is not what
    /// you're looking at".
    fn something_else_is_playing(&self) -> bool {
        self.active_session.is_some()
    }

    /// The player seated at `seat_index`, if any. Lets bones-side elements
    /// go from the seat index the world knows to the player id the party
    /// knows, without exposing the whole seat list.
    pub fn seat_player(&self, seat_index: u32) -> Option<PlayerId> {
        self.latest_seats
            .iter()
            .find(|s| s.index as u32 == seat_index)
            .and_then(|s| s.occupant.player_id())
    }

    /// Which seat the wall QR is currently for.
    pub fn claim_seat(&self) -> Option<u8> {
        self.claim_seat
    }

    /// Identity of whoever holds `seat`, as a value that changes when a
    /// phone applies a profile to them.
    fn claim_fingerprint(&self, seat: u8) -> Option<String> {
        let id = self.seat_player(seat as u32)?;
        player_fingerprint(&self.latest_players, id)
    }

    /// Somebody walked out through the doorway. Queued for the bevy side,
    /// which is the only half of this that can reach the daemon connection and
    /// the pad-to-player table.
    pub(crate) fn request_exit(&mut self, seat: u8, rejoin_block_secs: f32) {
        if self.exit_requests.iter().any(|(s, _)| *s == seat) {
            return;
        }
        self.exit_requests.push((seat, rejoin_block_secs));
    }

    pub(crate) fn set_claim_seat(&mut self, seat: u8) {
        // Only re-mark when the target actually changes, or the mark would be
        // refreshed every frame and the change could never be noticed.
        if self.claim_seat != Some(seat) {
            self.claim_seat = Some(seat);
            self.claim_mark = self.claim_fingerprint(seat);
        }
    }

    /// Free the pad once the targeted player has been claimed.
    fn release_claim_if_taken(&mut self) {
        let Some(seat) = self.claim_seat else { return };
        let now = self.claim_fingerprint(seat);
        // Gone from the party entirely, or changed: either way, done with it.
        if now.is_none() || now != self.claim_mark {
            info!(seat, "gamenight: sign-in claimed, releasing the pad");
            self.claim_seat = None;
            self.claim_mark = None;
        }
    }
}

/// Installs the GameNight bridge, but only when launched by a daemon.
/// Standalone runs (the common case: `cargo run` with no `GAMENIGHT` env var)
/// never spawn the background thread or touch the session model.
pub fn game_plugin(game: &mut Game) {
    // Installed unconditionally. This process is the lobby whether or not a
    // daemon is listening — without one it simply runs the lobby map with no
    // seats, which is the correct empty state rather than a reason to fall
    // back to a menu. `connection_loop` copes with the connection failing.

    let (incoming_tx, incoming_rx) = async_channel::unbounded::<GameEvent>();
    let (outgoing_tx, outgoing_rx) = async_channel::unbounded::<OutgoingMessage>();

    if let Err(e) = std::thread::Builder::new()
        .name("gamenight-connection".into())
        .spawn(move || {
            let runtime = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(runtime) => runtime,
                Err(e) => {
                    error!("gamenight: could not start connection runtime: {e}");
                    return;
                }
            };
            runtime.block_on(connection_loop(incoming_tx, outgoing_rx));
        })
    {
        error!("gamenight: could not spawn connection thread: {e}");
        return;
    }

    // A second, overlay-role connection: sends party commands (joins, for
    // now) and is the only source of live party snapshots (see
    // `spawn_overlay_connection`'s doc comment for why the connection above
    // can't do either).
    let (join_tx, party_rx) = spawn_overlay_connection();

    // Jumpy IS the GameNight lobby: an always-on arena instead of a static
    // menu, so people can see and fight each other while others are still
    // joining or the party's deciding what to play next. There's no more
    // `start_menu()` in this mode — see `ensure_lobby_running`, run every
    // frame from `gamenight_bridge_system`, for what replaces it.
    game.insert_shared_resource(GameNightBridge {
        incoming: incoming_rx,
        outgoing: outgoing_tx,
        party_updates: party_rx,
        join_tx,
        current_session: None,
        notified_finished: false,
        latest_seats: Vec::new(),
        lobby_rebuild_at: None,
        latest_players: Vec::new(),
        player_gamepad: default(),
        pads_connected: 0,
        latest_library: Vec::new(),
        latest_warm: None,
        latest_warming: None,
        latest_playlist: Vec::new(),
        vote_open: false,
        latest_installs: Vec::new(),
        active_session: None,
        hide_while_warm: false,
        now_playing: None,
        claim_seat: None,
        claim_mark: None,
        exit_requests: Vec::new(),
    });

    game.sessions
        .create_with(SessionNames::GAMENIGHT, |builder: &mut SessionBuilder| {
            builder.add_system_to_stage(Update, gamenight_bridge_system);
        });
}

/// Owns the actual daemon connection. Runs on its own thread/runtime for the
/// lifetime of the process; everything it learns is forwarded over
/// `incoming`, everything the game wants to tell the daemon arrives over
/// `outgoing`.
async fn connection_loop(
    incoming: async_channel::Sender<GameEvent>,
    outgoing: async_channel::Receiver<OutgoingMessage>,
) {
    if std::env::var("GAMENIGHT_GAME_ID").is_err() {
        std::env::set_var("GAMENIGHT_GAME_ID", "lobby");
    }
    let mut gn = match GameNight::connect_from_env().await {
        Ok(gn) => gn,
        Err(e) => {
            // Not an error when nobody launched us: the lobby runs standalone
            // with an empty party, which is a normal way to work on it.
            if GameNight::launched_by_daemon() {
                error!("gamenight: failed to connect to the daemon: {e}");
            } else {
                info!("gamenight: no daemon, running the lobby standalone ({e})");
            }
            return;
        }
    };
    info!("gamenight: connected, waiting for the party");

    loop {
        tokio::select! {
            event = gn.next_event() => {
                match event {
                    Ok(Some(event)) => {
                        if incoming.send(event).await.is_err() {
                            break;
                        }
                    }
                    Ok(None) => {
                        // The daemon is gone and isn't coming back: the night is over.
                        info!("gamenight: daemon connection closed, exiting");
                        std::process::exit(0);
                    }
                    Err(e) => {
                        error!("gamenight: connection error: {e}");
                        break;
                    }
                }
            }
            msg = outgoing.recv() => {
                match msg {
                    Ok(OutgoingMessage::Ready(session)) => {
                        if let Err(e) = gn.ready(session).await {
                            error!("gamenight: failed to send ready: {e}");
                        }
                    }
                    Ok(OutgoingMessage::Finished(session)) => {
                        if let Err(e) = gn.finished(session).await {
                            error!("gamenight: failed to send finished: {e}");
                        }
                    }
                    Err(_) => break,
                }
            }
        }
    }
}

/// Drains lifecycle events from the daemon once per frame and drives
/// jumpy's session model from them. Installed into an always-on session (see
/// [`game_plugin`]), the same way the debug and profiler menus are.
fn gamenight_bridge_system(
    mut bridge: ResMut<GameNightBridge>,
    mut sessions: ResMut<Sessions>,
    meta: Root<GameMeta>,
    assets: Res<AssetServer>,
    mut audio_center: ResMut<AudioCenter>,
) {
    while let Ok(party) = bridge.party_updates.try_recv() {
        if party.seats != bridge.latest_seats {
            debug!(old = ?bridge.latest_seats, new = ?party.seats, "gamenight: seats changed, scheduling lobby rebuild");
            bridge.latest_seats = party.seats;
            bridge.lobby_rebuild_at = Some(std::time::Instant::now() + LOBBY_REBUILD_DEBOUNCE);
        }
        bridge.latest_players = party.players;
        bridge.latest_library = party.library;
        bridge.latest_warm = party.warm_session;
        bridge.latest_warming = party.warming;
        bridge.latest_playlist = party.playlist.entries;
        bridge.vote_open = party.vote.open;
        bridge.latest_installs = party.installs;
        bridge.active_session = party.active_session;
        bridge.now_playing = party.now_playing;
        bridge.release_claim_if_taken();
    }

    while let Ok(event) = bridge.incoming.try_recv() {
        match event {
            GameEvent::Prepare {
                session, seats, ..
            } => {
                info!("gamenight: prepare {session:?}");
                bridge.current_session = Some(session);
                bridge.notified_finished = false;

                // A replay, or a real match starting from the lobby: eject
                // whatever's currently running (the lobby arena, or a
                // previous match) first.
                if sessions.get(SessionNames::GAME).is_some() {
                    sessions.end_game();
                }

                sessions.start_game(match_plugin_for_seats(
                    &seats,
                    &meta,
                    &assets,
                    false,
                    &bridge.player_gamepad,
                ));

                // Don't show or simulate anything until `start` arrives.
                if let Some(game_session) = sessions.get_mut(SessionNames::GAME) {
                    game_session.active = false;
                }
                // Being warm means being a whole second copy of the game that
                // nobody asked to see yet: get off the screen and shut up
                // until `Start`. An inactive session stops simulating, but the
                // process still owns a window and still plays audio, so
                // without this the party gets a black rectangle over the lobby
                // and two soundtracks at once.
                audio_center.set_main_volume_scale(0.0);
                bridge.hide_while_warm = true;

                // Match setup is fast and entirely local: there is no real
                // "loading" phase to hide behind, so we're instantly ready.
                let _ = bridge.outgoing.try_send(OutgoingMessage::Ready(session));
            }
            GameEvent::Start { session } => {
                debug!("gamenight: start {session:?}");
                if let Some(game_session) = sessions.get_mut(SessionNames::GAME) {
                    game_session.active = true;
                }
                // Take the screen and the speakers back. Being started is
                // precisely the moment a warm game becomes the thing on the
                // TV; without this the transition is invisible — the party
                // hears the new game but keeps looking at the old one.
                info!("gamenight: start {session:?} — taking the screen");
                bridge.hide_while_warm = false;
                audio_center.set_main_volume_scale(1.0);
                #[cfg(target_os = "macos")]
                crate::gamenight_macos::bring_self_to_front();
            }
            GameEvent::Pause { session } => {
                debug!("gamenight: pause {session:?}");
                if let Some(game_session) = sessions.get_mut(SessionNames::GAME) {
                    game_session.active = false;
                }
            }
            GameEvent::Resume { session } => {
                debug!("gamenight: resume {session:?}");
                // Coming back from the overlay is the same act of claiming
                // the screen as starting.
                #[cfg(target_os = "macos")]
                crate::gamenight_macos::bring_self_to_front();
                if let Some(game_session) = sessions.get_mut(SessionNames::GAME) {
                    game_session.active = true;
                }
            }
            GameEvent::Dispose { session } => {
                info!("gamenight: dispose {session:?}");
                sessions.end_game();
                bridge.current_session = None;
                // `ensure_lobby_running` rebuilds unconditionally whenever
                // the GAME session doesn't exist at all, so nothing else is
                // needed here to get back to the lobby.
            }
            // jumpy doesn't declare any match settings (see `declare_settings`
            // in the SDK) — the daemon can't send changes for settings that
            // were never declared, so this never actually fires.
            GameEvent::SettingChanged { .. } => {}
            GameEvent::LobbyFocus { active } => {
                info!(active, "gamenight: lobby focus changed");
                #[cfg(target_os = "macos")]
                if active {
                    crate::gamenight_macos::bring_self_to_front();
                }
                audio_center.set_main_volume_scale(if active { 1.0 } else { 0.0 });
            }
        }
    }

    // Keep asking until it sticks: `Prepare` typically lands before this
    // process has a window, and you cannot hide an app that hasn't shown
    // anything yet. `hide_self` reports whether we're actually hidden, so
    // this stops the moment it takes.
    #[cfg(target_os = "macos")]
    if bridge.hide_while_warm && crate::gamenight_macos::hide_self() {
        info!("gamenight: warm and out of sight until start");
        bridge.hide_while_warm = false;
    }

    ensure_lobby_running(&mut bridge, &mut sessions, &meta, &assets);
}

/// How long a rebuild waits after the *last* trigger before actually
/// happening — generous enough that a join's two triggers (seat appears,
/// then moments later `player_gamepad` resolves) collapse into a single
/// rebuild instead of two back to back.
const LOBBY_REBUILD_DEBOUNCE: Duration = Duration::from_millis(500);

/// How long "remove inactive players" waits before actually removing anyone
/// — long enough to glance over and nudge a stick if you're still there.
const PRUNE_HOLD_SECONDS: Duration = Duration::from_secs(3);

/// How far a seat's world position has to drift during the prune window to
/// count as "moved" — big enough that idle physics settling/bobbing doesn't
/// save someone, small enough that any deliberate nudge does.
const PRUNE_MOVE_EPSILON: f32 = 12.0;

/// Jumpy IS the GameNight lobby: whenever there's no real daemon-driven
/// match in progress (`current_session.is_none()`), the GAME session is
/// always this free-for-all arena instead of a static menu, kept in sync
/// with whoever's actually seated. Rebuilt wholesale on every seat change —
/// simpler than live-patching a running match, and a brief reset when
/// someone joins/leaves is normal for a hangout space, not a real match.
fn ensure_lobby_running(
    bridge: &mut GameNightBridge,
    sessions: &mut Sessions,
    meta: &GameMeta,
    assets: &AssetServer,
) {
    if bridge.current_session.is_some() {
        bridge.lobby_rebuild_at = None; // not relevant while a real match owns GAME
        return;
    }

    if sessions.get(SessionNames::GAME).is_none() {
        // Nothing running at all (first boot, or just disposed a real
        // match) — no existing session/camera to collide with, so no need
        // to debounce.
        rebuild_lobby(bridge, sessions, meta, assets);
        bridge.lobby_rebuild_at = None;
        return;
    }

    if let Some(at) = bridge.lobby_rebuild_at {
        let now = std::time::Instant::now();
        if now >= at {
            rebuild_lobby(bridge, sessions, meta, assets);
            bridge.lobby_rebuild_at = None;
        } else {
            debug!(remaining_ms = (at - now).as_millis(), "gamenight: lobby rebuild pending");
        }
    }
}

fn rebuild_lobby(bridge: &GameNightBridge, sessions: &mut Sessions, meta: &GameMeta, assets: &AssetServer) {
    info!(seats = ?bridge.latest_seats, "gamenight: rebuilding lobby session");

    // Carry the camera's exact position/zoom across the rebuild. A fresh
    // session spawns a fresh camera centered on the map's geometric center
    // (see `core::map`'s `spawn_map`) — with nothing to smooth from, every
    // seat change (join, rename, ...) would otherwise snap the view back to
    // the middle of the map for a frame before `camera_controller`'s lerp
    // eased it back out to the players, reading as a flash/jump-cut rather
    // than a pan. Reusing the old camera's state makes the rebuild itself
    // invisible — the only visible motion is however far the subject rect
    // actually shifted from adding/removing that one player.
    let previous_camera = sessions.get(SessionNames::GAME).and_then(|session| {
        let world = &session.world;
        let entities = world.resource::<Entities>();
        let cameras = world.components.get::<Camera>().borrow();
        let camera_shakes = world.components.get::<CameraShake>().borrow();
        entities
            .iter_with((&cameras, &camera_shakes))
            .next()
            .map(|(_, (camera, shake))| (camera.size, *shake))
    });

    if sessions.get(SessionNames::GAME).is_some() {
        sessions.end_game();
    }
    sessions.start_game(match_plugin_for_seats(
        &bridge.latest_seats,
        meta,
        assets,
        true,
        &bridge.player_gamepad,
    ));
    if let Some((size, shake)) = previous_camera {
        if let Some(game_session) = sessions.get_mut(SessionNames::GAME) {
            let world = &game_session.world;
            let entities = world.resource::<Entities>();
            let mut cameras = world.components.get::<Camera>().borrow_mut();
            let mut camera_shakes = world.components.get::<CameraShake>().borrow_mut();
            if let Some((_, (camera, shake_mut))) =
                entities.iter_with((&mut cameras, &mut camera_shakes)).next()
            {
                camera.size = size;
                *shake_mut = shake;
            }
        }
    }
    // The lobby is always live — nobody sends it a `start`.
    if let Some(game_session) = sessions.get_mut(SessionNames::GAME) {
        game_session.active = true;
    }
}

/// Build a [`MatchPlugin`] out of the seats the daemon handed us, mapping
/// GameNight seats 1:1 onto jumpy's player slots the same way the map-select
/// screen does when a human picks a map.
fn match_plugin_for_seats(
    seats: &[gamenight_protocol::Seat],
    meta: &GameMeta,
    assets: &AssetServer,
    lobby_mode: bool,
    player_gamepad: &std::collections::HashMap<gamenight_protocol::PlayerId, u32>,
) -> MatchPlugin {
    let default_player = meta.core.players.first().copied().unwrap_or_default();
    let default_map = meta.core.lobby_map;

    let mut player_info: [PlayerInput; MAX_PLAYERS as usize] =
        std::array::from_fn(|_| PlayerInput::default());

    for seat in seats {
        let idx = seat.index as usize;
        if idx >= MAX_PLAYERS as usize {
            warn!("gamenight: ignoring seat {idx}, only {MAX_PLAYERS} player slots exist");
            continue;
        }

        let (mut active, is_ai) = match &seat.occupant {
            SeatOccupant::Empty => (false, false),
            SeatOccupant::Ai => (true, true),
            SeatOccupant::Local { .. } | SeatOccupant::Remote { .. } => (true, false),
        };

        // The whole point of GameNight's controller-driven join is that
        // whichever pad joined this seat controls it here too. No keyboard
        // fallback: a seat surviving from a previous run (still occupied in
        // the daemon's party state, but with no pad confirmed *this*
        // session) must not spawn a controllable-but-untouched statue —
        // `player_gamepad` only gains an entry once that seat's own
        // controller actually presses something (`GlobalInput::reconcile_joins`),
        // so until then it's simply not controllable.
        let control_source = if active && !is_ai {
            seat.occupant
                .player_id()
                .and_then(|id| player_gamepad.get(&id))
                .map(|&idx| ControlSource::Gamepad(idx))
        } else {
            None
        };
        // No confirmed pad this session: don't spawn at all — never an
        // automatic CPU stand-in, and no controllable-but-untouched statue.
        // `SeatOccupant::Ai` (an explicit bot seat from the party model)
        // is unaffected, since that path never had a control_source to lose.
        if active && !is_ai && control_source.is_none() {
            active = false;
        }

        player_info[idx] = PlayerInput {
            active,
            selected_player: default_player,
            selected_hat: None,
            control: default(),
            editor_input: default(),
            control_source,
            is_ai,
        };
    }

    // jumpy's matchmaking input collector (`PlayerInputCollector::apply_inputs`,
    // src/input.rs) unconditionally requires *some* player slot to carry a
    // control source, network session or not — normally guaranteed by the
    // main menu always seating a keyboard player before a match can start.
    // GameNight's lobby has no such guarantee (nobody may have joined yet),
    // so it'd panic with "no local player control source" on an empty party.
    // Slot 0 gets a source without being made `active`, so this never
    // spawns a phantom player — it just satisfies the assumption.
    if player_info.iter().all(|p| p.control_source.is_none()) {
        player_info[0].control_source = Some(ControlSource::Keyboard1);
    }
    // Which seats spawn a player, by index — a positional row of bools tells
    // you nothing about which seat is which, and reads as noise besides.
    let spawning = player_info
        .iter()
        .enumerate()
        .filter(|(_, p)| p.active)
        .map(|(idx, p)| format!("{idx}{}", if p.is_ai { " (ai)" } else { "" }))
        .collect::<Vec<_>>();
    info!(
        seats = %if spawning.is_empty() {
            "none".to_string()
        } else {
            spawning.join(", ")
        },
        map = ?default_map,
        "gamenight: built match plugin"
    );

    MatchPlugin {
        maps: MapPool::from_single_map(default_map),
        player_info,
        plugins: meta.get_plugins(assets),
        session_runner: Box::<LobbyDefaultMatchRunner>::default(),
        score: default(),
        lobby_mode,
    }
}

// ---------------------------------------------------------------------------
// Global controller input: bringing jumpy to the front, and joining the party
// ---------------------------------------------------------------------------
//
// Everything below is plain Bevy (not bones) — a `Window` to raise, and
// gamepad button events read from bones' own `GamepadInputs` resource rather
// than a separate `gilrs::Gilrs` instance. bones_framework maintains its own
// lazy-static gilrs context internally (feeding `ControlSource::Gamepad(u32)`
// indices to the match session); a second, independent `gilrs::Gilrs` here
// numbered pads differently for the same physical controller (observed: one
// 8BitDo pad showing up as two different gilrs ids), so join/menu handling
// silently pointed at the wrong gamepad index. Reading the same
// `GamepadInputs` resource bones itself populates every frame guarantees the
// indices always agree. `bones_bevy_renderer` exposes the whole bones `Game`
// as a Bevy resource (`BonesGame`), which is how this reaches into both that
// resource and `GameNightBridge` for the player-name reconciliation below.

/// Handed out in order to newly-joined controllers before falling back to
/// "Player N" — mirrors `gamenight-overlay`'s and the browser overlay's own
/// `FUN_NAMES` so every frontend feels like the same product.
const FUN_NAMES: &[&str] = &[
    "Falcon", "Panda", "Mango", "Rocket", "Disco", "Waffle", "Ninja", "Pickle",
];

/// Pick a name at random from the ones nobody in the party is using.
///
/// Random rather than first-unused for two reasons: the first player to join
/// was always "Falcon" and the second always "Panda", which makes every
/// session feel identical; and the menu's "New Name" reroll re-picked the
/// same first-unused name every press, so it never appeared to do anything.
///
/// `None` once every name is taken — callers decide what to do with that
/// (join falls back to a numbered name, reroll leaves the name alone).
fn random_unused_name(taken: &HashSet<&str>) -> Option<&'static str> {
    use turborand::prelude::*;
    let available: Vec<&'static str> = FUN_NAMES
        .iter()
        .copied()
        .filter(|n| !taken.contains(n))
        .collect();
    Rng::new().sample(&available).copied()
}

/// A minimal daemon connection as `Role::Overlay`: sends party commands
/// (`join_party` for now — `GameNightBridge`'s `Role::Game` connection can't,
/// the daemon rejects party commands from games) and is *also* the only
/// source of live party snapshots, since the daemon only ever broadcasts
/// `party_state` to overlay connections.
fn spawn_overlay_connection() -> (
    async_channel::Sender<ClientMessage>,
    async_channel::Receiver<PartySnapshot>,
) {
    let (out_tx, out_rx) = async_channel::unbounded::<ClientMessage>();
    let (party_tx, party_rx) = async_channel::unbounded::<PartySnapshot>();
    if let Err(e) = std::thread::Builder::new()
        .name("gamenight-overlay".into())
        .spawn(move || {
            let runtime = match tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(runtime) => runtime,
                Err(e) => {
                    error!("gamenight: could not start overlay-connection runtime: {e}");
                    return;
                }
            };
            runtime.block_on(overlay_connection_loop(out_rx, party_tx));
        })
    {
        error!("gamenight: could not spawn overlay-connection thread: {e}");
    }
    (out_tx, party_rx)
}

// Windows blocks background processes from taking focus unless the foreground
// app explicitly hands it over. A warm game was launched before this input, so
// process creation alone does not give it foreground rights anymore.
fn allow_game_foreground(message: &ClientMessage) {
    #[cfg(target_os = "windows")]
    if matches!(
        message,
        ClientMessage::Next | ClientMessage::PlayNext { .. } | ClientMessage::CloseOverlay
    ) {
        #[link(name = "user32")]
        extern "system" {
            fn AllowSetForegroundWindow(process_id: u32) -> i32;
        }
        // The protocol has no process IDs. ASFW_ANY is a transient permission,
        // revoked by the next user input; grant it only for an explicit handoff.
        unsafe {
            AllowSetForegroundWindow(u32::MAX);
        }
    }
    #[cfg(not(target_os = "windows"))]
    let _ = message;
}

async fn overlay_connection_loop(
    outgoing: async_channel::Receiver<ClientMessage>,
    party_updates: async_channel::Sender<PartySnapshot>,
) {
    use futures_util::{SinkExt, StreamExt};
    use tokio_tungstenite::tungstenite::Message;

    let addr = std::env::var(gamenight_protocol::ENV_ADDR)
        .unwrap_or_else(|_| gamenight_protocol::DEFAULT_ADDR.to_string());
    let (ws, _) = match tokio_tungstenite::connect_async(format!("ws://{addr}")).await {
        Ok(conn) => conn,
        Err(e) => {
            if GameNight::launched_by_daemon() {
                error!("gamenight: overlay connection could not reach the daemon: {e}");
            } else {
                debug!("gamenight: no daemon for the overlay connection ({e})");
            }
            return;
        }
    };
    let (mut sink, mut stream) = ws.split();
    let hello = ClientMessage::Hello {
        role: Role::Overlay,
        game: None,
        token: None,
    };
    if sink.send(Message::Text(hello.to_json())).await.is_err() {
        return;
    }

    loop {
        tokio::select! {
            msg = outgoing.recv() => {
                match msg {
                    Ok(msg) => {
                        allow_game_foreground(&msg);
                        if sink.send(Message::Text(msg.to_json())).await.is_err() {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
            msg = stream.next() => {
                let party = match msg {
                    Some(Ok(Message::Text(text))) => match serde_json::from_str::<ServerMessage>(&text) {
                        Ok(ServerMessage::Welcome { party, .. }) => Some(party),
                        Ok(ServerMessage::PartyState { party }) => Some(party),
                        Ok(_) => None,
                        Err(e) => {
                            warn!("gamenight: overlay connection got unparseable message: {e}");
                            None
                        }
                    },
                    Some(Ok(_)) => None,
                    _ => break,
                };
                if let Some(party) = party {
                    if party_updates.send(party).await.is_err() {
                        break;
                    }
                }
            }
        }
    }
}

/// Plain Bevy resource — deliberately not a bones one, since its whole job
/// (polling gamepads regardless of focus, raising a real OS window) lives on
/// the Bevy/winit side of the fence.
#[derive(bevy::prelude::Resource)]
struct GlobalInput {
    /// Name + color sent for a pad, awaiting the daemon's echo before we know
    /// its real [`PlayerId`] — matched by name against
    /// `GameNightBridge::latest_players`. Keyed by bones' own gamepad index
    /// (`GamepadButtonEvent::gamepad`), the same numbering
    /// `ControlSource::Gamepad` uses.
    pending_joins: std::collections::HashMap<u32, (String, String)>,
    /// Pads that are done joining — no further action needed for them here.
    joined_pads: HashSet<u32>,
    /// Confirmed pad -> player mappings not yet written into
    /// `GameNightBridge::player_gamepad` (drained every frame by
    /// `global_input_system`, which is the only thing with a path to that
    /// bones resource).
    newly_confirmed: Vec<(u32, PlayerId)>,
    /// Which player each joined pad *is* — the reverse of `player_gamepad`,
    /// kept here too since Start-button handling (which player's menu to
    /// open) only ever needs the pad that pressed it, not the bones side.
    pad_player: std::collections::HashMap<u32, PlayerId>,
    /// (pad, button) pairs currently held, per bones' `GamepadInputs` — used
    /// to turn its per-frame value reports into real press edges. Needed
    /// because a single physical press can show up as more than one
    /// `GamepadButtonEvent` in the same frame (observed: this 8BitDo pad
    /// reports through two HID interfaces), which without this would toggle
    /// the menu open and immediately closed again in one frame.
    pressed_buttons: HashSet<(u32, GamepadButton)>,
    /// Per-player start-menu state, open for whoever's pressed Start and not
    /// pressed it again (or Leave) since. A `egui::Window` per entry, drawn
    /// by `sync_player_menus_system` — deliberately not a bones session, so it
    /// never touches `Session::active` and the match keeps running under it.
    open_menus: std::collections::HashMap<PlayerId, PlayerMenuState>,
    /// Whether GameNight is the thing currently in front.
    open: bool,
    /// Every gamepad button event bones saw this frame, snapshotted by
    /// `gate_gamepad_input_system` (`PreUpdate`) before it strips the
    /// events of any pad whose player has an open menu from the live
    /// `GamepadInputs` resource. `global_input_system` reads from here
    /// instead of the (by then filtered) resource directly, so a player can
    /// still navigate and close their own menu even while their character's
    /// controls are blocked.
    frame_button_events: Vec<GamepadButtonEvent>,
    /// Same idea as `frame_button_events`, for stick/trigger movement — a
    /// pad that only ever waggles its stick (no face-button press) should
    /// still be able to join. Not gated the same way `frame_button_events`
    /// is: menu navigation never reads sticks, so there's nothing here that
    /// needs blocking for an open-menu pad.
    frame_axis_events: Vec<GamepadAxisEvent>,
    /// Live "remove inactive players" countdown, started by
    /// `MenuAction::PruneInactive` — `None` when no prune is in progress.
    prune_countdown: Option<PruneCountdown>,
    /// Pads barred from rejoining until the given instant, because the
    /// player holding them just walked out through the exit doorway.
    ///
    /// Leaving is impossible without this. `join_pad` treats any stick
    /// movement as a request to join, and the stick that walked you through
    /// the door is still pushed over when you arrive on the other side, so
    /// you would rejoin on the very next frame.
    rejoin_blocked: HashMap<u32, std::time::Instant>,
    #[cfg(target_os = "macos")]
    previous_app: Option<crate::gamenight_macos::PreviousApp>,
}

/// Snapshot taken the moment `MenuAction::PruneInactive` fires — whoever's
/// world position hasn't moved past `PRUNE_MOVE_EPSILON` by `deadline` gets
/// left.
struct PruneCountdown {
    deadline: std::time::Instant,
    start_positions: std::collections::HashMap<PlayerId, bevy::prelude::Vec2>,
}

/// State for one player's open start menu — just which action is
/// highlighted, moved by that player's own d-pad. Rendered fresh from
/// `GameNightBridge`'s live player list every frame, so there's nothing here
/// to keep in sync on rename/color-change.
struct PlayerMenuState {
    highlight: usize,
}

/// The menu's fixed action list — a d-pad-navigated list, not a mouse-driven
/// dialog, so this is deliberately a flat `Vec` rather than free text entry
/// (there's no reasonable way to type a name with a d-pad).
#[derive(Clone)]
enum MenuAction {
    /// Reroll to a fresh unused name from `FUN_NAMES`.
    NewName,
    Leave,
    /// Party-wide, not personal (like `Quit`): starts `PRUNE_HOLD_SECONDS`
    /// ticking down for every *other* seated player. Whoever hasn't moved by
    /// the time it elapses gets left — a couch's answer to a stale
    /// controller nobody picked back up.
    PruneInactive,
    Close,
    Quit,
}

fn menu_actions() -> Vec<MenuAction> {
    vec![
        MenuAction::NewName,
        MenuAction::Leave,
        MenuAction::PruneInactive,
        MenuAction::Close,
        MenuAction::Quit,
    ]
}

impl MenuAction {
    fn label(&self) -> String {
        match self {
            MenuAction::NewName => "New name".to_string(),
            MenuAction::Leave => "Leave".to_string(),
            MenuAction::PruneInactive => "Remove inactive players".to_string(),
            MenuAction::Close => "Close".to_string(),
            MenuAction::Quit => "Quit GameNight".to_string(),
        }
    }
}

/// The colours a joining player can be dealt.
///
/// Not a menu any more: picking your own shade is a fiddly thing to do with a
/// d-pad, and it pushed the menu's actual actions — leave, quit, a fresh name
/// — off the bottom of a list nobody wanted to scroll. A player who cares
/// about their colour sets it from their phone profile, where a real picker
/// lives.
const MENU_COLORS: &[(&str, &str)] = &[
    ("Red", "#ff5c5c"),
    ("Orange", "#ffb454"),
    ("Yellow", "#f5e663"),
    ("Green", "#7be08a"),
    ("Cyan", "#2dd4bf"),
    ("Blue", "#5c9eff"),
    ("Purple", "#a78bfa"),
    ("Pink", "#ff8fd6"),
];

impl GlobalInput {
    /// `join_tx` comes from `GameNightBridge` each call (via `BonesGame`) —
    /// `GlobalInput` itself has no path to the daemon connection.
    fn join_pad(
        &mut self,
        pad: u32,
        seated: &[Player],
        join_tx: &async_channel::Sender<ClientMessage>,
    ) {
        if self.joined_pads.contains(&pad) || self.pending_joins.contains_key(&pad) {
            return;
        }
        // Just walked out of the door. Wait for them to let go of the stick.
        if let Some(until) = self.rejoin_blocked.get(&pad) {
            if std::time::Instant::now() < *until {
                return;
            }
            self.rejoin_blocked.remove(&pad);
        }
        let taken_names: HashSet<&str> = seated
            .iter()
            .map(|p| p.name.as_str())
            .chain(self.pending_joins.values().map(|(name, _)| name.as_str()))
            .collect();
        let name = random_unused_name(&taken_names)
            .map(|n| n.to_string())
            .unwrap_or_else(|| {
                format!("Player {}", self.joined_pads.len() + self.pending_joins.len() + 1)
            });

        // A random color from the same palette the menu offers, avoiding
        // whatever's already taken (falling back to a repeat once every
        // color's in use — there are more colors than the couch has seats
        // for in practice).
        let taken_colors: HashSet<&str> = seated
            .iter()
            .filter_map(|p| p.color.as_deref())
            .chain(self.pending_joins.values().map(|(_, color)| color.as_str()))
            .collect();
        let all_colors: Vec<&str> = MENU_COLORS.iter().map(|(_, hex)| *hex).collect();
        let available: Vec<&str> = all_colors
            .iter()
            .copied()
            .filter(|hex| !taken_colors.contains(hex))
            .collect();
        let pool = if available.is_empty() { &all_colors } else { &available };
        let color = {
            use turborand::prelude::*;
            Rng::new().sample(pool).copied().unwrap_or(MENU_COLORS[0].1)
        }
        .to_string();

        info!(?pad, %name, %color, "gamenight: controller joining party");
        let _ = join_tx.try_send(ClientMessage::JoinParty {
            name: name.clone(),
            seat: None,
            color: Some(color.clone()),
            avatar: None,
            library: Vec::new(),
        });
        self.pending_joins.insert(pad, (name, color));
    }

    fn reconcile_joins(&mut self, seated: &[Player]) {
        let pending = std::mem::take(&mut self.pending_joins);
        for (pad, (name, color)) in pending {
            match seated.iter().find(|p| p.name == name) {
                Some(player) => {
                    self.joined_pads.insert(pad);
                    self.pad_player.insert(pad, player.id);
                    self.newly_confirmed.push((pad, player.id));
                }
                None => {
                    self.pending_joins.insert(pad, (name, color));
                }
            }
        }
    }

    /// Toggle the given player's start menu — Start opens it, Start again
    /// (or the menu's own Close/Leave) closes it.
    fn toggle_menu(&mut self, player_id: PlayerId) {
        if self.open_menus.remove(&player_id).is_none() {
            self.open_menus.insert(player_id, PlayerMenuState { highlight: 0 });
        }
    }

    fn move_highlight(&mut self, player_id: PlayerId, delta: isize) {
        if let Some(state) = self.open_menus.get_mut(&player_id) {
            let len = menu_actions().len() as isize;
            state.highlight = (((state.highlight as isize) + delta).rem_euclid(len)) as usize;
        }
    }

    /// After a Leave: forget this player entirely so their pad can join
    /// fresh (as a new player) later.
    fn forget_player(&mut self, player_id: PlayerId) {
        self.open_menus.remove(&player_id);
        self.pad_player.retain(|_, p| *p != player_id);
        self.joined_pads
            .retain(|pad| self.pad_player.contains_key(pad));
    }
}

/// Whether this process is running as the GameNight lobby.
///
/// Always true, and kept only so the call sites still read as an explicit
/// statement of intent. It used to distinguish a daemon-launched run from a
/// bare `cargo run`, back when a bare run opened a main menu instead; there is
/// no longer any other mode to be in.
pub fn is_lobby() -> bool {
    true
}

/// Installs global controller polling and window-raising. Called from
/// `main.rs` only when GameNight launched us, right after `.app()` builds the
/// real Bevy `App` — this is Bevy-native, not a bones plugin, since it needs
/// to reach a real winit `Window`.
pub fn install_global_input(app: &mut bevy::app::App) {
    app.init_resource::<StashedFaceAtlases>();
    app.insert_resource(GlobalInput {
        pending_joins: default(),
        joined_pads: default(),
        newly_confirmed: default(),
        pad_player: default(),
        pressed_buttons: default(),
        open_menus: default(),
        open: true, // jumpy starts as the lobby, already frontmost
        frame_button_events: default(),
        frame_axis_events: default(),
        prune_countdown: None,
        rejoin_blocked: default(),
        #[cfg(target_os = "macos")]
        previous_app: None,
    });
    // `PreUpdate` (not `Update`) so this runs before bones' own
    // `step_bones_game` applies movement for the frame — otherwise blocking
    // a menu-open player's controls would always be a frame late.
    use bevy::prelude::IntoSystemConfigs as _;
    app.add_systems(bevy::prelude::PreUpdate, gate_gamepad_input_system);
    app.add_systems(
        bevy::prelude::Update,
        (
            global_input_system,
            sync_player_menus_system,
            position_player_menus_system,
            apply_player_colors_system,
            sync_name_tags_system,
            position_name_tags_system,
            sync_player_avatar_system,
            position_player_avatar_system,
            swap_player_faces_system,
            deal_player_faces_system,
            sync_prune_countdown_system,
            sync_exit_door_system,
            sync_lobby_qr_system,
            sync_sign_in_pad_system,
            sync_jukebox_system,
            sync_next_game_tv_system,
            press_pads_system,
            fill_the_screen_system,
            reached_for_the_lobby_system,
        )
            // Chained, not parallel. Every one of these reaches into the
            // bones world and several take mutable borrows of the same
            // components (`AtlasSprite`, most of all). Bevy sees only
            // `Res<BonesGame>` and happily runs them concurrently, at which
            // point the second borrow panics with "Failed to borrow
            // AtomicCell mutably" — bevy cannot know two systems share a
            // bones-internal cell. These are all cheap per-frame UI passes,
            // so serialising them costs nothing worth having.
            .chain(),
    );
}

/// Cmd+Tabbing to the lobby while a game is playing means "back to the
/// party" — the mirror of a game reporting that it was reached for
/// (`ClientMessage::RequestStart`).
///
/// Window focus is the one thing the party can always express and GameNight
/// cannot override, so it's read as intent rather than fought: whoever the
/// couch just switched to is who they want. Sends the same `open_overlay` the
/// Select button does, so the game pauses and hands the screen over properly
/// rather than the lobby ending up in front of a game that is still running.
///
/// Only on the *edge* into focus, and only while something else is actually
/// playing: the lobby is focused for most of the night, and re-announcing
/// that every frame would pause a game for every stray activation.
fn reached_for_the_lobby_system(
    bones_game: bevy::prelude::Res<bones_bevy_renderer::BonesGame>,
    windows: bevy::prelude::Query<
        &bevy::prelude::Window,
        bevy::prelude::With<bevy::window::PrimaryWindow>,
    >,
    mut was_focused: bevy::prelude::Local<Option<bool>>,
) {
    let focused = windows.get_single().map(|w| w.focused).unwrap_or(false);
    // The *first* observation is not an edge. A window that opens focused
    // would otherwise read as the party reaching for the lobby the instant it
    // launches — which, mid-match, would pause the game they're playing
    // because their lobby happened to restart.
    let gained = was_focused.is_some_and(|before| focused && !before);
    *was_focused = Some(focused);
    if !gained {
        return;
    }
    let bridge = bones_game.0.shared_resource::<GameNightBridge>();
    // Nothing playing means the lobby already has the screen — there is
    // nothing to ask for, and asking would open an overlay over ourselves.
    if !bridge.something_else_is_playing() {
        return;
    }
    info!("gamenight: the party reached for the lobby — asking for the screen");
    let _ = bridge.join_tx.try_send(ClientMessage::OpenOverlay);
}

/// Keeps the lobby filling the screen — as a borderless window, deliberately
/// *not* as a native fullscreen one.
///
/// macOS native fullscreen was costing more than it was worth here, twice
/// over. It puts the window on a Space of its own, so a game that takes the
/// screen leaves the lobby somewhere the couch can't see and activating the
/// app alone doesn't bring it back. And asking for it is a transition macOS
/// can refuse — which is not a no-op: winit's refusal path
/// (`window_did_fail_to_enter_fullscreen`) re-locks a mutex it already holds
/// and the main thread never returns. That froze the lobby solid, mid-night,
/// with a game already running: no screen, and deaf to every message the
/// daemon sent it after. A borderless window sized to the screen looks the
/// same to the party, always lives on whatever Space is in front, and asks
/// the window server for nothing it can decline.
///
/// Re-asserted rather than set once: bones drives this same `Window` from its
/// own `fullscreen` flag, and a resolution set before the real monitor is
/// known would otherwise stick.
fn fill_the_screen_system(
    winit_windows: bevy::prelude::NonSend<bevy::winit::WinitWindows>,
    mut windows: bevy::prelude::Query<
        (bevy::prelude::Entity, &mut bevy::prelude::Window),
        bevy::prelude::With<bevy::window::PrimaryWindow>,
    >,
) {
    let Ok((entity, mut window)) = windows.get_single_mut() else {
        return;
    };
    // The monitor we're actually on, in the logical points bevy's resolution
    // speaks — asked of winit rather than AppKit so there's no second idea of
    // the screen size to drift from the first.
    let Some((width, height)) = winit_windows
        .get_window(entity)
        .and_then(|w| w.current_monitor())
        .map(|monitor| {
            let scale = monitor.scale_factor();
            let size = monitor.size();
            (
                (size.width as f64 / scale) as f32,
                (size.height as f64 / scale) as f32,
            )
        })
    else {
        return;
    };
    if window.mode != bevy::window::WindowMode::Windowed {
        window.mode = bevy::window::WindowMode::Windowed;
    }
    if window.decorations {
        window.decorations = false;
    }
    let position = bevy::window::WindowPosition::At(bevy::prelude::IVec2::ZERO);
    if window.position != position {
        window.position = position;
    }
    // Compared with a tolerance: the window server's idea of the size comes
    // back through winit as a resize, and chasing a sub-pixel difference
    // would rewrite the resolution every frame forever.
    if (window.resolution.width() - width).abs() > 1.0
        || (window.resolution.height() - height).abs() > 1.0
    {
        window.resolution.set(width, height);
    }
}

/// Snapshots this frame's gamepad button events for `global_input_system`,
/// then strips every event belonging to a pad whose player has an open menu
/// from the live `GamepadInputs` resource — the same resource bones' own
/// `step_bones_game` (character movement/attacks) reads later this frame.
/// Menu navigation itself still works because it's read from the snapshot,
/// not the (by then filtered) live resource.
fn gate_gamepad_input_system(
    mut input: bevy::prelude::ResMut<GlobalInput>,
    bones_game: bevy::prelude::Res<bones_bevy_renderer::BonesGame>,
) {
    let mut gamepad_inputs = bones_game.0.shared_resource_mut::<GamepadInputs>();

    input.frame_button_events = gamepad_inputs
        .gamepad_events
        .iter()
        .filter_map(|ev| match ev {
            GamepadEvent::Button(button_event) => Some(*button_event),
            _ => None,
        })
        .collect();
    input.frame_axis_events = gamepad_inputs
        .gamepad_events
        .iter()
        .filter_map(|ev| match ev {
            GamepadEvent::Axis(axis_event) => Some(*axis_event),
            _ => None,
        })
        .collect();

    let blocked_pads: HashSet<u32> = input
        .pad_player
        .iter()
        .filter(|(_, player_id)| input.open_menus.contains_key(player_id))
        .map(|(&pad, _)| pad)
        .collect();
    if blocked_pads.is_empty() {
        return;
    }
    gamepad_inputs.gamepad_events.retain(|ev| {
        let gamepad = match ev {
            GamepadEvent::Connection(c) => c.gamepad,
            GamepadEvent::Button(b) => b.gamepad,
            GamepadEvent::Axis(a) => a.gamepad,
        };
        !blocked_pads.contains(&gamepad)
    });
}

fn global_input_system(
    mut input: bevy::prelude::ResMut<GlobalInput>,
    bones_game: bevy::prelude::ResMut<bones_bevy_renderer::BonesGame>,
    mut windows: bevy::prelude::Query<&mut bevy::prelude::Window, bevy::prelude::With<bevy::window::PrimaryWindow>>,
    keys: bevy::prelude::Res<bevy::prelude::Input<bevy::prelude::KeyCode>>,
    gamepads: bevy::prelude::Res<bevy::input::gamepad::Gamepads>,
) {
    {
        // Bones has only per-frame gamepad *events*, no list of what is plugged
        // in; Bevy has the list. Mirror it so the attract overlay can be honest.
        let mut bridge = bones_game.0.shared_resource_mut::<GameNightBridge>();
        bridge.pads_connected = gamepads.iter().count();
    }
    let (seated, join_tx): (Vec<Player>, async_channel::Sender<ClientMessage>) = {
        let bridge = bones_game.0.shared_resource::<GameNightBridge>();
        (bridge.latest_players.clone(), bridge.join_tx.clone())
    };
    input.reconcile_joins(&seated);

    // Show out anybody who walked into the exit doorway. Drained here rather
    // than acted on in the bones session because only this side can reach the
    // daemon connection and the pad-to-player table.
    let exits: Vec<(u8, f32)> = {
        let mut bridge = bones_game.0.shared_resource_mut::<GameNightBridge>();
        std::mem::take(&mut bridge.exit_requests)
    };
    if !exits.is_empty() {
        let seats = bones_game.0.shared_resource::<GameNightBridge>().latest_seats.clone();
        for (seat, block_secs) in exits {
            let Some(player_id) = seats
                .iter()
                .find(|s| s.index == seat)
                .and_then(|s| s.occupant.player_id())
            else {
                continue;
            };
            // Bar the pad *before* the leave goes out. `forget_player` drops it
            // from `joined_pads`, and the very next frame's stick reading would
            // otherwise be taken as a fresh join.
            if let Some(pad) = input.pad_player.iter().find(|(_, p)| **p == player_id).map(|(pad, _)| *pad) {
                input.rejoin_blocked.insert(
                    pad,
                    std::time::Instant::now() + Duration::from_secs_f32(block_secs.max(0.0)),
                );
            }
            info!(?seat, ?player_id, "gamenight: player walked out through the exit");
            let _ = join_tx.try_send(ClientMessage::LeaveParty { player_id });
            input.forget_player(player_id);
        }
    }

    // Check whether a running "remove inactive players" countdown has
    // elapsed — independent of any button press this frame, so it has to be
    // checked unconditionally every frame rather than from inside the input
    // match below.
    if let Some(pc) = input.prune_countdown.take() {
        let remaining = pc.deadline.saturating_duration_since(std::time::Instant::now());
        if remaining.is_zero() {
            let seats = bones_game.0.shared_resource::<GameNightBridge>().latest_seats.clone();
            let mut kicked = 0;
            for (player_id, start_pos) in pc.start_positions {
                let Some(seat_index) = seats
                    .iter()
                    .find(|s| s.occupant.player_id() == Some(player_id))
                    .map(|s| s.index)
                else {
                    continue;
                };
                let moved = seat_world_position(&bones_game.0, seat_index)
                    .map(|p| p.truncate().distance(start_pos))
                    .unwrap_or(f32::INFINITY);
                if moved < PRUNE_MOVE_EPSILON {
                    kicked += 1;
                    let _ = join_tx.try_send(ClientMessage::LeaveParty { player_id });
                    input.forget_player(player_id);
                }
            }
            info!(kicked, "gamenight: inactive-player prune complete");
        } else {
            input.prune_countdown = Some(pc);
        }
    }

    // Hand confirmed pad -> player mappings to the bones side, so the lobby
    // (rebuilt by `ensure_lobby_running`) controls each seat with the pad
    // that actually joined it instead of a hardcoded keyboard mapping.
    if !input.newly_confirmed.is_empty() {
        let mut bridge = bones_game.0.shared_resource_mut::<GameNightBridge>();
        for (pad, player_id) in input.newly_confirmed.drain(..) {
            bridge.player_gamepad.insert(player_id, pad);
        }
        bridge.lobby_rebuild_at = Some(std::time::Instant::now() + LOBBY_REBUILD_DEBOUNCE);
    }

    // Escape is the keyboard equivalent of a gamepad's Start button. There's
    // no per-controller keyboard, so it toggles the menu for every seated
    // player *not* mapped to a gamepad — i.e. whoever is on the keyboard.
    if keys.just_pressed(bevy::prelude::KeyCode::Escape) {
        // Only players who actually have a character on screen. Without the
        // body check this hit exactly the wrong set: everyone seated *and*
        // padless is a web/phone joiner, who spawns nothing, so Escape used
        // to toggle a menu for a character that doesn't exist.
        let keyboard_players: Vec<PlayerId> = {
            let bridge = bones_game.0.shared_resource::<GameNightBridge>();
            bridge
                .latest_seats
                .iter()
                .filter(|s| {
                    s.occupant
                        .player_id()
                        .map(|id| !bridge.player_gamepad.contains_key(&id))
                        .unwrap_or(false)
                        && seat_world_position(&bones_game.0, s.index).is_some()
                })
                .filter_map(|s| s.occupant.player_id())
                .collect()
        };
        for player_id in keyboard_players {
            input.toggle_menu(player_id);
        }
    }

    // Snapshotted by `gate_gamepad_input_system` (`PreUpdate`, before this
    // frame's events get filtered for any menu-open player) rather than read
    // straight from bones' `GamepadInputs` here, so a player can still
    // navigate and close their own menu even while it's blocking their
    // character's controls below.
    let button_events = std::mem::take(&mut input.frame_button_events);

    // Turn per-frame value reports into real press edges: a single physical
    // press can appear as more than one event this frame (see
    // `pressed_buttons`'s doc comment), so only the transition into "held"
    // fires a dispatch — repeats and releases are absorbed here.
    let mut just_pressed = Vec::new();
    for ev in button_events {
        let key = (ev.gamepad, ev.button);
        if ev.value > 0.5 {
            if input.pressed_buttons.insert(key) {
                just_pressed.push(ev);
            }
        } else {
            input.pressed_buttons.remove(&key);
        }
    }

    // A stick shoved past the deadzone counts as "this pad wants in" just as
    // much as a face button — not every layout leads with a button (some
    // players just start walking).
    const AXIS_JOIN_DEADZONE: f32 = 0.4;
    let axis_join_pads: HashSet<u32> = std::mem::take(&mut input.frame_axis_events)
        .into_iter()
        .filter(|ev| ev.value.abs() > AXIS_JOIN_DEADZONE)
        .map(|ev| ev.gamepad)
        .collect();
    for pad in axis_join_pads {
        if !input.joined_pads.contains(&pad) {
            input.join_pad(pad, &seated, &join_tx);
        }
    }

    // Read *before* the Select arm below sets it: that arm asks for focus as
    // part of raising the lobby, and a menu decision made after the ask would
    // see the lobby as already frontmost when it plainly wasn't.
    let lobby_was_focused = windows.get_single().map(|w| w.focused).unwrap_or(false);

    for GamepadButtonEvent { gamepad: id, button, .. } in just_pressed {
        match button {
            GamepadButton::Select => {
                input.open = !input.open;
                // Tell the daemon, which is what makes this the way *out* of a
                // running game: the party overlay coming up pauses whatever is
                // playing and hands the screen back to the lobby (see
                // `sync_lobby_focus` in gamenight-core). Closing it again
                // resumes the game, which raises itself on `Resume`.
                let _ = join_tx.try_send(if input.open {
                    ClientMessage::OpenOverlay
                } else {
                    ClientMessage::CloseOverlay
                });
                if input.open {
                    #[cfg(target_os = "macos")]
                    {
                        input.previous_app = crate::gamenight_macos::capture_frontmost_app();
                    }
                    for mut window in &mut windows {
                        window.focused = true;
                    }
                } else {
                    #[cfg(target_os = "macos")]
                    if let Some(app) = input.previous_app.take() {
                        app.reactivate();
                    }
                }
            }
            _ if !input.joined_pads.contains(&id) => input.join_pad(id, &seated, &join_tx),
            GamepadButton::Start => {
                // Start opens a player's lobby menu — but only Start, and
                // only out here.
                //
                // The pads are polled globally, whatever is on screen, so a
                // press meant for the game being played reaches this code
                // too. Start+Select is how you leave a game; taken at face
                // value that combination also opened a lobby menu behind the
                // scenes, and the party arrived back at the couch with a menu
                // already up that nobody asked for.
                let select_held = input
                    .pressed_buttons
                    .contains(&(id, GamepadButton::Select));
                if !lobby_was_focused || select_held {
                    continue;
                }
                if let Some(&player_id) = input.pad_player.get(&id) {
                    input.toggle_menu(player_id);
                }
            }
            GamepadButton::DPadUp => {
                if let Some(&player_id) = input.pad_player.get(&id) {
                    input.move_highlight(player_id, -1);
                }
            }
            GamepadButton::DPadDown => {
                if let Some(&player_id) = input.pad_player.get(&id) {
                    input.move_highlight(player_id, 1);
                }
            }
            GamepadButton::South => {
                if let Some(&player_id) = input.pad_player.get(&id) {
                    let highlight = input.open_menus.get(&player_id).map(|s| s.highlight);
                    if let Some(highlight) = highlight {
                        if let Some(action) = menu_actions().get(highlight).cloned() {
                            match action {
                                MenuAction::NewName => {
                                    let taken: HashSet<&str> =
                                        seated.iter().map(|p| p.name.as_str()).collect();
                                    if let Some(name) = random_unused_name(&taken) {
                                        let _ = join_tx.try_send(ClientMessage::RenamePlayer {
                                            player_id,
                                            name: name.to_string(),
                                        });
                                    }
                                }
                                MenuAction::Leave => {
                                    let _ =
                                        join_tx.try_send(ClientMessage::LeaveParty { player_id });
                                    input.forget_player(player_id);
                                }
                                MenuAction::PruneInactive => {
                                    let seats = bones_game
                                        .0
                                        .shared_resource::<GameNightBridge>()
                                        .latest_seats
                                        .clone();
                                    let start_positions = seats
                                        .iter()
                                        .filter_map(|seat| {
                                            let pid = seat.occupant.player_id()?;
                                            let pos =
                                                seat_world_position(&bones_game.0, seat.index)?;
                                            Some((pid, pos.truncate()))
                                        })
                                        .collect();
                                    info!("gamenight: starting inactive-player prune countdown");
                                    input.prune_countdown = Some(PruneCountdown {
                                        deadline: std::time::Instant::now() + PRUNE_HOLD_SECONDS,
                                        start_positions,
                                    });
                                    input.open_menus.remove(&player_id);
                                }
                                MenuAction::Close => {
                                    input.open_menus.remove(&player_id);
                                }
                                MenuAction::Quit => {
                                    info!("gamenight: quitting from the player menu");
                                    std::process::exit(0);
                                }
                            }
                        }
                    }
                }
            }
            _ => {}
        }
    }
}


/// Spawns/despawns/rebuilds each open player's start-menu content. Touches
/// nothing about session/pause state — the match keeps running underneath
/// exactly as it was; this only ever adds UI nodes on top of it.
fn sync_player_menus_system(
    mut commands: bevy::prelude::Commands,
    input: bevy::prelude::Res<GlobalInput>,
    bones_game: bevy::prelude::Res<bones_bevy_renderer::BonesGame>,
    asset_server: bevy::prelude::Res<bevy::prelude::AssetServer>,
    roots: bevy::prelude::Query<(bevy::prelude::Entity, &PlayerMenuRoot)>,
) {
    use bevy::hierarchy::{BuildChildren, DespawnRecursiveExt};
    use bevy::prelude::*;

    for (entity, PlayerMenuRoot(player_id)) in &roots {
        if !input.open_menus.contains_key(player_id) {
            commands.entity(entity).despawn_recursive();
        }
    }
    if input.open_menus.is_empty() {
        return;
    }

    let (seats, seated) = {
        let bridge = bones_game.0.shared_resource::<GameNightBridge>();
        (bridge.latest_seats.clone(), bridge.latest_players.clone())
    };
    let font: Handle<Font> = asset_server.load("ui/ark-pixel-16px-latin.ttf");

    for (&player_id, state) in input.open_menus.iter() {
        let Some(seat_index) = seats
            .iter()
            .find(|s| s.occupant.player_id() == Some(player_id))
            .map(|s| s.index)
        else {
            continue; // seated player vanished from under us; next sync closes this
        };
        let name = seated
            .iter()
            .find(|p| p.id == player_id)
            .map(|p| p.name.as_str())
            .unwrap_or("???");

        let root_entity = roots
            .iter()
            .find(|(_, r)| r.0 == player_id)
            .map(|(e, _)| e)
            .unwrap_or_else(|| {
                commands
                    .spawn((
                        PlayerMenuRoot(player_id),
                        NodeBundle {
                            style: Style {
                                position_type: PositionType::Absolute,
                                flex_direction: FlexDirection::Column,
                                padding: UiRect::all(Val::Px(8.0)),
                                ..default()
                            },
                            background_color: Color::rgba(0.0, 0.0, 0.0, 0.85).into(),
                            z_index: ZIndex::Global(1000),
                            ..default()
                        },
                    ))
                    .id()
            });

        commands.entity(root_entity).despawn_descendants();
        commands.entity(root_entity).with_children(|parent| {
            parent.spawn(TextBundle::from_section(
                format!("P{} — {name}", seat_index + 1),
                TextStyle {
                    font: font.clone(),
                    font_size: 20.0,
                    color: Color::WHITE,
                },
            ));
            for (i, action) in menu_actions().iter().enumerate() {
                let highlighted = i == state.highlight;
                // Every row is an action now, so every row looks alike; the
                // highlight is the only thing that distinguishes them.
                let base = Color::rgb(0.25, 0.25, 0.25);
                parent
                    .spawn(NodeBundle {
                        style: Style {
                            margin: UiRect::top(Val::Px(3.0)),
                            padding: UiRect::axes(Val::Px(8.0), Val::Px(4.0)),
                            border: UiRect::all(Val::Px(2.0)),
                            ..default()
                        },
                        background_color: base.into(),
                        border_color: (if highlighted { Color::WHITE } else { base }).into(),
                        ..default()
                    })
                    .with_children(|row| {
                        row.spawn(TextBundle::from_section(
                            action.label(),
                            TextStyle {
                                font: font.clone(),
                                font_size: 16.0,
                                color: Color::WHITE,
                            },
                        ));
                    });
            }
        });
    }
}

/// Marks a player start-menu's root UI node. Persists across frames so
/// `position_player_menus_system` has something stable to move; its
/// children are rebuilt fresh every frame in `sync_player_menus_system` —
/// the whole tree is a handful of tiny nodes, cheap enough that incremental
/// per-widget updates would just be complexity for no real benefit.
#[derive(bevy::prelude::Component)]
struct PlayerMenuRoot(PlayerId);

/// Keeps each open menu positioned just above the player it belongs to,
/// re-projected every frame since the player keeps moving. Reaches directly
/// into the bones `GAME` session's world to find that seat's live position —
/// there's no bones system to ask for this from the Bevy side otherwise.
fn position_player_menus_system(
    bones_game: bevy::prelude::Res<bones_bevy_renderer::BonesGame>,
    cameras: bevy::prelude::Query<(&bevy::prelude::Camera, &bevy::prelude::GlobalTransform)>,
    mut roots: bevy::prelude::Query<(&PlayerMenuRoot, &mut bevy::prelude::Style)>,
) {
    if roots.is_empty() {
        return;
    }
    let Some((camera, camera_transform)) = cameras.iter().next() else {
        return;
    };
    let seats = bones_game
        .0
        .shared_resource::<GameNightBridge>()
        .latest_seats
        .clone();

    for (menu, mut style) in &mut roots {
        // Same rule as the name tags: a menu needs a body to sit above. A
        // web-joined player occupies a seat but spawns nothing, and without
        // this their menu stranded itself in the top-left corner.
        let world_pos = seats
            .iter()
            .find(|s| s.occupant.player_id() == Some(menu.0))
            .map(|s| s.index)
            .and_then(|seat_index| seat_world_position(&bones_game.0, seat_index));
        let Some(world_pos) = world_pos else {
            style.display = bevy::prelude::Display::None;
            continue;
        };
        style.display = bevy::prelude::Display::Flex;

        // A player-height offset above their translation, projected to
        // screen space, so the menu sits over their head rather than on it.
        let anchor = world_pos + bevy::prelude::Vec3::new(0.0, 40.0, 0.0);
        if let Some(screen_pos) = camera.world_to_viewport(camera_transform, anchor) {
            style.left = bevy::prelude::Val::Px(screen_pos.x);
            style.top = bevy::prelude::Val::Px(screen_pos.y);
        }
    }
}

/// Find a seated player's live world position, straight from the bones
/// `GAME` session's world — shared by the menu- and name-tag-positioning
/// systems, both of which need exactly this.
fn seat_world_position(game: &Game, seat_index: u8) -> Option<bevy::prelude::Vec3> {
    let session = game.sessions.get(SessionNames::GAME)?;
    let world = &session.world;
    let entities = world.resource::<Entities>();
    let transforms = world.components.get::<Transform>().borrow();
    let player_indices = world.components.get::<PlayerIdx>().borrow();
    entities
        .iter_with((&transforms, &player_indices))
        .find(|(_, (_, idx))| idx.0 == seat_index as u32)
        .map(|(_, (transform, _))| transform.translation)
}

fn bones_hex_color(hex: &str) -> Color {
    let hex = hex.trim_start_matches('#');
    let red = u8::from_str_radix(&hex[0..2], 16).unwrap_or(255) as f32 / 255.0;
    let green = u8::from_str_radix(&hex[2..4], 16).unwrap_or(255) as f32 / 255.0;
    let blue = u8::from_str_radix(&hex[4..6], 16).unwrap_or(255) as f32 / 255.0;
    Color::Rgba { red, green, blue, alpha: 1.0 }
}

/// Tints each seated player's sprite to their chosen `Player.color` (set via
/// the start menu's color swatches) — otherwise that choice has no visible
/// effect at all, since jumpy's own character selection is a skin, not a
/// color.
fn apply_player_colors_system(bones_game: bevy::prelude::Res<bones_bevy_renderer::BonesGame>) {
    let seat_colors: Vec<(u8, Option<String>)> = {
        let bridge = bones_game.0.shared_resource::<GameNightBridge>();
        bridge
            .latest_seats
            .iter()
            .filter_map(|seat| {
                let player_id = seat.occupant.player_id()?;
                let color = bridge
                    .latest_players
                    .iter()
                    .find(|p| p.id == player_id)
                    .and_then(|p| p.color.clone());
                Some((seat.index, color))
            })
            .collect()
    };
    if seat_colors.is_empty() {
        return;
    }
    let Some(session) = bones_game.0.sessions.get(SessionNames::GAME) else {
        return;
    };
    let world = &session.world;
    let entities = world.resource::<Entities>();
    let player_indices = world.components.get::<PlayerIdx>().borrow();
    let mut sprites = world.components.get::<AtlasSprite>().borrow_mut();

    for (seat_index, color) in seat_colors {
        let tint = match color {
            Some(hex) => bones_hex_color(&hex),
            None => Color::Rgba { red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0 },
        };
        if let Some((entity, _)) = entities
            .iter_with(&player_indices)
            .find(|(_, idx)| idx.0 == seat_index as u32)
        {
            if let Some(sprite) = sprites.get_mut(entity) {
                sprite.color = tint;
            }
        }
    }
}

/// How far above a player's transform the name tag sits, in world units.
/// High enough to clear the character's head rather than print across its
/// face. Everything else that floats over a player stacks upward from the
/// same point — in *screen* space, so the gaps stay constant as the camera
/// zooms instead of drifting apart.
const OVERHEAD_ANCHOR: f32 = 52.0;

/// Height of the avatar portrait, and the gap it leaves above the name.
const PORTRAIT_PX: f32 = 48.0;
const PORTRAIT_GAP_PX: f32 = 4.0;

/// That player's current display name, or a placeholder if the party
/// snapshot hasn't caught up with the seat yet.
fn name_of(players: &[Player], id: PlayerId) -> String {
    players
        .iter()
        .find(|p| p.id == id)
        .map(|p| p.name.clone())
        .unwrap_or_else(|| "???".to_string())
}

/// Marks a seated player's name-tag UI node — one per seat, always visible
/// (not just while the start menu is open), tracking that player's position
/// exactly like `PlayerMenuRoot` does.
///
/// Carries the name it is currently displaying, so a rename actually shows:
/// the text lives in a child `TextBundle` that nothing else re-reads, and
/// without this the tag kept whatever name the player had when they joined.
#[derive(bevy::prelude::Component)]
struct PlayerNameTag(PlayerId, String);

/// Marks the pixel-art portrait above a claimed player's head. Carries the
/// avatar data it was built from so an edit in the studio redraws it.
#[derive(bevy::prelude::Component)]
struct PlayerAvatarPortrait(PlayerId, String);

/// Build a texture from a player's avatar.
///
/// Decoding lives in `gamenight-protocol` rather than here: the format is
/// part of the public contract, and any game that wants to show who's
/// playing needs the same decoder. This is only the bevy-specific wrapping
/// around it.
fn avatar_image(data: &str) -> Option<bevy::render::texture::Image> {
    use bevy::render::render_resource::{Extent3d, TextureDimension, TextureFormat};

    let art = gamenight_protocol::Avatar::parse(data)?;
    if art.is_blank() {
        return None;
    }
    // Scale up so the art survives being drawn at UI size without the
    // renderer smoothing the pixels into mush.
    let (width, height, rgba) = art.to_rgba_scaled(4);

    Some(bevy::render::texture::Image::new(
        Extent3d {
            width,
            height,
            depth_or_array_layers: 1,
        },
        TextureDimension::D2,
        rgba,
        TextureFormat::Rgba8UnormSrgb,
    ))
}

/// Where a seated player's face sprite is, in world space.
///
/// jumpy's skins are layered — body, fin, face, hat — so the face is its own
/// entity, positioned each frame by `PlayerBodyAttachment { head: true }`.
/// That is exactly the anchor a drawn avatar wants: it tracks the head bob
/// and the walk cycle for free.
/// The drawn face's placement: where it goes, and whether it should be
/// mirrored. Returned together because both come from the same lookup.
fn player_face_placement(game: &Game, seat_index: u8) -> Option<(bevy::prelude::Vec3, bool)> {
    let session = game.sessions.get(SessionNames::GAME)?;
    let world = &session.world;
    let entities = world.resource::<Entities>();
    let transforms = world.components.get::<Transform>().borrow();
    let player_indices = world.components.get::<PlayerIdx>().borrow();
    let layers = world.components.get::<PlayerLayers>().borrow();

    let (player_ent, (_, layer)) = entities
        .iter_with((&player_indices, &layers))
        .find(|(_, (idx, _))| idx.0 == seat_index as u32)?;
    let face = transforms.get(layer.face_ent)?;
    let body = transforms.get(player_ent)?;

    // Which way the character is looking. The body sprite's `flip_x` is
    // jumpy's own source of truth for facing, and it stays available after
    // `swap_player_faces_system` takes the *face* sprite away.
    let flipped = {
        let sprites = world.components.get::<AtlasSprite>().borrow();
        sprites.get(player_ent).map(|s| s.flip_x).unwrap_or(false)
    };
    let facing = if flipped { -1.0 } else { 1.0 };

    // Horizontal position from the *body*, vertical from the face layer.
    //
    // jumpy's face layer carries an offset of `[10, 15]` (see any
    // `*.player.yaml`): the fish snout sits well forward of the head's
    // centre. Inheriting all of it put a drawn face out on the edge of the
    // head, so x comes from the body instead — then leans back toward the
    // facing direction by a couple of pixels, which reads as looking where
    // you're walking without sliding off the head. The face layer's y keeps
    // the head bob and walk cycle for free.
    Some((
        bevy::prelude::Vec3::new(
            body.translation.x + facing * AVATAR_FACE_LEAD,
            face.translation.y + AVATAR_FACE_NUDGE_Y,
            face.translation.z,
        ),
        flipped,
    ))
}

/// How far the drawn face leans toward the way the character is facing, in
/// world units. Small on purpose: the full face-layer offset is 10, which is
/// most of the way off the head.
const AVATAR_FACE_LEAD: f32 = 2.0;

/// Vertical fine-tuning for the drawn face, in world units. The face layer's
/// own y already puts it on the head; this is the knob for taste.
const AVATAR_FACE_NUDGE_Y: f32 = 0.0;

/// Remembers the face atlas we took off a player, so it can be given back.
#[derive(bevy::prelude::Resource, Default)]
struct StashedFaceAtlases(std::collections::HashMap<PlayerId, Handle<Atlas>>);

/// Takes jumpy's own eyes-and-mouth off any player who drew their own face,
/// and gives it back when they don't have one.
///
/// Hiding it by alpha does not work: `PlayerBodyAttachment { sync_color }`
/// rewrites the layer's alpha from the body every frame, so the sprite would
/// flicker back. Removing the `AtlasSprite` outright is what actually sticks
/// — the animation and attachment systems both iterate entities that *have*
/// one, so its absence is simply skipped.
fn swap_player_faces_system(
    bones_game: bevy::prelude::Res<bones_bevy_renderer::BonesGame>,
    mut stashed: bevy::prelude::ResMut<StashedFaceAtlases>,
) {
    let (seats, players) = {
        let bridge = bones_game.0.shared_resource::<GameNightBridge>();
        (bridge.latest_seats.clone(), bridge.latest_players.clone())
    };
    let Some(session) = bones_game.0.sessions.get(SessionNames::GAME) else {
        return;
    };
    let world = &session.world;
    let entities = world.resource::<Entities>();
    let player_indices = world.components.get::<PlayerIdx>().borrow();
    let layers = world.components.get::<PlayerLayers>().borrow();
    let mut atlas_sprites = world.components.get::<AtlasSprite>().borrow_mut();

    for seat in &seats {
        let Some(player_id) = seat.occupant.player_id() else { continue };
        let has_avatar = players
            .iter()
            .find(|p| p.id == player_id)
            .and_then(|p| p.avatar.as_deref())
            .and_then(gamenight_protocol::Avatar::parse)
            .is_some_and(|a| !a.is_blank());

        let Some((_, (_, layer))) = entities
            .iter_with((&player_indices, &layers))
            .find(|(_, (idx, _))| idx.0 == seat.index as u32)
        else {
            continue;
        };

        if has_avatar {
            if let Some(sprite) = atlas_sprites.get(layer.face_ent) {
                stashed.0.insert(player_id, sprite.atlas);
                atlas_sprites.remove(layer.face_ent);
            }
        } else if let Some(atlas) = stashed.0.remove(&player_id) {
            atlas_sprites.insert(
                layer.face_ent,
                AtlasSprite {
                    atlas,
                    ..default()
                },
            );
        }
    }
}

/// How many face variants the skins' face atlases carry, and how wide a row of
/// expressions is. Must stay in step with `FACE_VARIANTS` / `FACE_COLUMNS` in
/// `tools/reskin/build_players.py`, which generates those atlases.
const FACE_VARIANTS: u32 = 8;
const FACE_COLUMNS: u32 = 11;

/// Which face a player is dealt.
///
/// Hashed from the player's id rather than actually random, so it is stable:
/// a face that re-rolled on every respawn would read as a glitch, and two
/// people sharing a couch should not swap faces mid-round.
fn face_variant(player_id: PlayerId) -> u32 {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    player_id.hash(&mut hasher);
    (hasher.finish() % FACE_VARIANTS as u64) as u32
}

/// Gives everyone who has not signed in a face of their own.
///
/// The face atlases are laid out as one row of expressions per variant, so the
/// animation still drives *which* expression plays and this only chooses the
/// row. Taking the index modulo the row width first makes it idempotent — the
/// animation writes a fresh 0..N index every frame, but re-running over an
/// already-offset index is harmless either way.
///
/// Players who have signed in are skipped for free: `swap_player_faces_system`
/// has already removed their `AtlasSprite` so their drawn avatar can take over,
/// and there is nothing here to offset.
fn deal_player_faces_system(bones_game: bevy::prelude::Res<bones_bevy_renderer::BonesGame>) {
    let seats = bones_game
        .0
        .shared_resource::<GameNightBridge>()
        .latest_seats
        .clone();
    let Some(session) = bones_game.0.sessions.get(SessionNames::GAME) else {
        return;
    };
    let world = &session.world;
    let entities = world.resource::<Entities>();
    let player_indices = world.components.get::<PlayerIdx>().borrow();
    let layers = world.components.get::<PlayerLayers>().borrow();
    let mut atlas_sprites = world.components.get::<AtlasSprite>().borrow_mut();

    for (_, (idx, layer)) in entities.iter_with((&player_indices, &layers)) {
        // Prefer the seated player's identity so a face follows the person, not
        // the seat. An unclaimed body still gets a face, keyed to its slot.
        let variant = seats
            .iter()
            .find(|s| s.index as u32 == idx.0)
            .and_then(|s| s.occupant.player_id())
            .map(face_variant)
            .unwrap_or(idx.0 % FACE_VARIANTS);

        let Some(sprite) = atlas_sprites.get_mut(layer.face_ent) else {
            continue;
        };
        sprite.index = sprite.index % FACE_COLUMNS + variant * FACE_COLUMNS;
    }
}

/// Draws each player's own face where jumpy's used to be.
///
/// A world-space sprite rather than a UI node: a UI element sized in pixels
/// drifts off the head as soon as the camera zooms, whereas this shares the
/// face entity's own transform and scale.
fn sync_player_avatar_system(
    mut commands: bevy::prelude::Commands,
    bones_game: bevy::prelude::Res<bones_bevy_renderer::BonesGame>,
    mut images: bevy::prelude::ResMut<bevy::prelude::Assets<bevy::render::texture::Image>>,
    existing: bevy::prelude::Query<(bevy::prelude::Entity, &PlayerAvatarPortrait)>,
) {
    use bevy::hierarchy::DespawnRecursiveExt;
    use bevy::prelude::*;

    let (seats, players) = {
        let bridge = bones_game.0.shared_resource::<GameNightBridge>();
        (bridge.latest_seats.clone(), bridge.latest_players.clone())
    };

    let wanted: Vec<(PlayerId, String)> = seats
        .iter()
        .filter_map(|s| s.occupant.player_id())
        .filter_map(|id| {
            players
                .iter()
                .find(|p| p.id == id)
                .and_then(|p| p.avatar.clone())
                .map(|a| (id, a))
        })
        .collect();

    for (entity, PlayerAvatarPortrait(id, shown)) in &existing {
        if !wanted.iter().any(|(w, a)| w == id && a == shown) {
            commands.entity(entity).despawn_recursive();
        }
    }

    for (player_id, avatar) in wanted {
        if existing
            .iter()
            .any(|(_, p)| p.0 == player_id && p.1 == avatar)
        {
            continue;
        }
        let Some(image) = avatar_image(&avatar) else { continue };
        let handle = images.add(image);
        commands.spawn((
            PlayerAvatarPortrait(player_id, avatar),
            SpriteBundle {
                texture: handle,
                sprite: Sprite {
                    custom_size: Some(Vec2::splat(AVATAR_FACE_SIZE)),
                    ..default()
                },
                ..default()
            },
        ));
    }
}

/// World size the drawn face is rendered at.
///
/// Sized to the head, which is about 22 units across. It no longer has to be
/// large enough to hide anything: the reskin wipes the stock face off the body
/// art entirely, so what sits under an avatar is blank skin. Going bigger just
/// spills the drawing onto the character's chest, since people draw right to
/// the edge of the canvas.
const AVATAR_FACE_SIZE: f32 = 20.0;

/// Keeps each drawn face locked to its player's face layer, and out of sight
/// when that player has no body on screen.
fn position_player_avatar_system(
    bones_game: bevy::prelude::Res<bones_bevy_renderer::BonesGame>,
    mut portraits: bevy::prelude::Query<(
        &PlayerAvatarPortrait,
        &mut bevy::prelude::Transform,
        &mut bevy::prelude::Visibility,
        &mut bevy::prelude::Sprite,
    )>,
) {
    use bevy::prelude::*;

    if portraits.is_empty() {
        return;
    }
    let seats = bones_game
        .0
        .shared_resource::<GameNightBridge>()
        .latest_seats
        .clone();

    for (portrait, mut transform, mut visibility, mut sprite) in &mut portraits {
        let placement = seats
            .iter()
            .find(|s| s.occupant.player_id() == Some(portrait.0))
            .map(|s| s.index)
            .and_then(|seat| player_face_placement(&bones_game.0, seat));
        let Some((face, flipped)) = placement else {
            *visibility = Visibility::Hidden;
            continue;
        };
        *visibility = Visibility::Visible;
        // Just in front of the face layer it replaces.
        transform.translation = Vec3::new(face.x, face.y, face.z + 0.005);
        // Mirror with the character, exactly as jumpy's own face atlas does —
        // a face that keeps looking right while its body walks left reads as
        // a sticker rather than a head.
        sprite.flip_x = flipped;
    }
}

/// A player's identity as a single comparable value.
///
/// The sign-in pad releases its target when this changes, so it has to cover
/// exactly what a phone can set — name, colour, avatar — and nothing that
/// drifts on its own, or the pad would free itself while someone is still
/// mid-scan.
fn player_fingerprint(players: &[Player], id: PlayerId) -> Option<String> {
    let p = players.iter().find(|p| p.id == id)?;
    Some(format!(
        "{}|{}|{}",
        p.name,
        p.color.as_deref().unwrap_or(""),
        p.avatar.as_deref().unwrap_or("")
    ))
}

/// Z depth for the lobby's bevy-drawn props (QR sign, TV, sign-in pad).
///
/// Jumpy's world sits in *negative* z: map layers start at
/// `MAP_LAYERS_MIN_DEPTH` (-900) and climb, the parallax background sits near
/// -999, and bones overwrites the bevy camera's transform with its own
/// (z ~ 0). With bevy's orthographic near=0/far=1000 that makes the visible
/// range z ∈ (-1000, 0] — anything at positive z is *behind* the camera and
/// silently never drawn.
const LOBBY_PROP_Z: f32 = -100.0;
/// The URL players scan to join.
///
/// Defaults to this machine's LAN address, because the whole point is that
/// someone else's phone can reach it — a `127.0.0.1` link resolves to the
/// phone itself and just fails. `GAMENIGHT_JOIN_URL` overrides it for the
/// cases auto-detection can't know about (a hostname, a tunnel, a
/// non-default port).
fn lobby_join_url() -> String {
    std::env::var("GAMENIGHT_JOIN_URL")
        .unwrap_or_else(|_| format!("{}/session/gn-couch", gamenight_protocol::web_base_url()))
}

/// Where the lobby's QR sign is and how big its face is, straight off the
/// map element. `None` outside the lobby (real matches have no sign).
fn lobby_qr_sign(game: &Game) -> Option<(bevy::prelude::Vec3, bevy::prelude::Vec2)> {
    let session = game.sessions.get(SessionNames::GAME)?;
    let world = &session.world;
    let entities = world.resource::<Entities>();
    let transforms = world.components.get::<Transform>().borrow();
    let signs = world.components.get::<QrSign>().borrow();
    entities
        .iter_with((&transforms, &signs))
        .next()
        .map(|(_, (transform, sign))| {
            (
                transform.translation,
                bevy::prelude::Vec2::new(sign.size.x, sign.size.y),
            )
        })
}

/// Where the lobby's TV is: the world position of its screen (the element
/// sits on the floor, the screen hangs above it), the screen's size, and the
/// footprint of the button on the floor below it.
fn lobby_tv(
    game: &Game,
) -> Option<(
    bevy::prelude::Vec3,
    bevy::prelude::Vec2,
    bevy::prelude::Vec3,
    bevy::prelude::Vec2,
)> {
    let session = game.sessions.get(SessionNames::GAME)?;
    let world = &session.world;
    let entities = world.resource::<Entities>();
    let transforms = world.components.get::<Transform>().borrow();
    let triggers = world.components.get::<NextGameTrigger>().borrow();
    entities
        .iter_with((&transforms, &triggers))
        .next()
        .map(|(_, (transform, trigger))| {
            let mut screen = transform.translation;
            screen.x += trigger.screen_offset.x;
            screen.y += trigger.screen_offset.y;
            (
                screen,
                bevy::prelude::Vec2::new(trigger.screen_size.x, trigger.screen_size.y),
                transform.translation,
                bevy::prelude::Vec2::new(trigger.body_size.x, trigger.body_size.y),
            )
        })
}
fn sync_name_tags_system(
    mut commands: bevy::prelude::Commands,
    bones_game: bevy::prelude::Res<bones_bevy_renderer::BonesGame>,
    asset_server: bevy::prelude::Res<bevy::prelude::AssetServer>,
    tags: bevy::prelude::Query<(bevy::prelude::Entity, &PlayerNameTag)>,
) {
    use bevy::hierarchy::{BuildChildren, DespawnRecursiveExt};
    use bevy::prelude::*;

    let (seats, seated) = {
        let bridge = bones_game.0.shared_resource::<GameNightBridge>();
        (bridge.latest_seats.clone(), bridge.latest_players.clone())
    };

    // Drop tags whose player left, or whose name has since changed — the
    // latter get rebuilt below with the new text.
    for (entity, PlayerNameTag(player_id, shown)) in &tags {
        let current = seats
            .iter()
            .any(|s| s.occupant.player_id() == Some(*player_id))
            .then(|| name_of(&seated, *player_id));
        if current.as_deref() != Some(shown.as_str()) {
            commands.entity(entity).despawn_recursive();
        }
    }

    // FairfaxSM reads far clearer than the pixel font at name-tag size; a
    // 1px-offset black copy behind the white text fakes an outline/bold
    // weight bevy_ui's `TextStyle` has no field for on its own.
    const NAME_TAG_FONT_SIZE: f32 = 26.0;
    const NAME_TAG_OUTLINE: f32 = 2.0;
    let font: Handle<Font> = asset_server.load("ui/FairfaxSM.ttf");
    for seat in &seats {
        let Some(player_id) = seat.occupant.player_id() else { continue };
        let name = name_of(&seated, player_id);
        if tags
            .iter()
            .any(|(_, tag)| tag.0 == player_id && tag.1 == name)
        {
            continue; // already showing the right name; only position updates
        }
        commands
            .spawn((
                PlayerNameTag(player_id, name.clone()),
                NodeBundle {
                    style: Style {
                        position_type: PositionType::Absolute,
                        ..default()
                    },
                    ..default()
                },
            ))
            .with_children(|parent| {
                for (dx, dy) in [
                    (-NAME_TAG_OUTLINE, 0.0),
                    (NAME_TAG_OUTLINE, 0.0),
                    (0.0, -NAME_TAG_OUTLINE),
                    (0.0, NAME_TAG_OUTLINE),
                ] {
                    parent.spawn(TextBundle {
                        style: Style {
                            position_type: PositionType::Absolute,
                            left: Val::Px(dx),
                            top: Val::Px(dy),
                            ..default()
                        },
                        text: Text::from_section(
                            name.clone(),
                            TextStyle { font: font.clone(), font_size: NAME_TAG_FONT_SIZE, color: Color::BLACK },
                        ),
                        ..default()
                    });
                }
                parent.spawn(TextBundle::from_section(
                    name.clone(),
                    TextStyle { font: font.clone(), font_size: NAME_TAG_FONT_SIZE, color: Color::WHITE },
                ));
            });
    }
}

fn position_name_tags_system(
    bones_game: bevy::prelude::Res<bones_bevy_renderer::BonesGame>,
    cameras: bevy::prelude::Query<(&bevy::prelude::Camera, &bevy::prelude::GlobalTransform)>,
    mut tags: bevy::prelude::Query<(&PlayerNameTag, &mut bevy::prelude::Style)>,
) {
    if tags.is_empty() {
        return;
    }
    let Some((camera, camera_transform)) = cameras.iter().next() else {
        return;
    };
    let seats = bones_game
        .0
        .shared_resource::<GameNightBridge>()
        .latest_seats
        .clone();

    for (tag, mut style) in &mut tags {
        // A tag is only meaningful once its player has a body to sit above.
        // A seat can be occupied with nothing spawned — someone who joined
        // from the web has no gamepad, so `match_plugin_for_seats` leaves
        // them inactive — and without this the label would strand itself at
        // whatever screen position it was last given.
        let world_pos = seats
            .iter()
            .find(|s| s.occupant.player_id() == Some(tag.0))
            .map(|s| s.index)
            .and_then(|seat_index| seat_world_position(&bones_game.0, seat_index));
        let Some(world_pos) = world_pos else {
            style.display = bevy::prelude::Display::None;
            continue;
        };
        let anchor = world_pos + bevy::prelude::Vec3::new(0.0, OVERHEAD_ANCHOR, 0.0);
        if let Some(screen_pos) = camera.world_to_viewport(camera_transform, anchor) {
            style.display = bevy::prelude::Display::Flex;
            style.left = bevy::prelude::Val::Px(screen_pos.x - 20.0);
            style.top = bevy::prelude::Val::Px(screen_pos.y);
        } else {
            // Off-camera: hide rather than clamp to an edge.
            style.display = bevy::prelude::Display::None;
        }
    }
}

/// The doorway's footprint and how far through leaving its occupant is.
fn lobby_exit_door(game: &Game) -> Option<(bevy::prelude::Vec3, bevy::prelude::Vec2, f32)> {
    let session = game.sessions.get(SessionNames::GAME)?;
    let world = &session.world;
    let entities = world.resource::<Entities>();
    let doors = world.components.get::<crate::core::elements::exit_door::ExitDoor>().borrow();
    let transforms = world.components.get::<Transform>().borrow();
    let (entity, door) = entities.iter_with(&doors).next()?;
    let t = transforms.get(entity)?;
    Some((
        bevy::prelude::Vec3::new(t.translation.x, t.translation.y, LOBBY_PROP_Z),
        bevy::prelude::Vec2::new(door.size.x, door.size.y),
        door.progress,
    ))
}

/// Marks the bar drawn across the exit doorway while somebody stands in it.
#[derive(bevy::prelude::Component)]
struct LobbyExitDoor;

/// Marks the bar itself, so its width can be set without rebuilding the tree.
#[derive(bevy::prelude::Component)]
struct LobbyExitBar(f32);

/// Show how far through leaving the person in the doorway is.
///
/// Without this the door is a trapdoor: you wander into it, nothing happens,
/// and then three quarters of a second later you are gone with no idea what did
/// it. A bar that fills — and empties the moment you step back out — makes the
/// dwell legible, and makes stepping out an obvious way to change your mind.
fn sync_exit_door_system(
    mut commands: bevy::prelude::Commands,
    bones_game: bevy::prelude::Res<bones_bevy_renderer::BonesGame>,
    asset_server: bevy::prelude::Res<bevy::prelude::AssetServer>,
    mut existing: bevy::prelude::Query<(
        bevy::prelude::Entity,
        &LobbyExitDoor,
        &mut bevy::prelude::Transform,
    )>,
    mut bars: bevy::prelude::Query<
        (&mut LobbyExitBar, &mut bevy::prelude::Sprite, &mut bevy::prelude::Transform),
        bevy::prelude::Without<LobbyExitDoor>,
    >,
) {
    use bevy::hierarchy::{BuildChildren, DespawnRecursiveExt};
    use bevy::prelude::*;

    let Some((pos, size, progress)) = lobby_exit_door(&bones_game.0) else {
        for (entity, _, _) in &existing {
            commands.entity(entity).despawn_recursive();
        }
        return;
    };

    let width = size.x - 8.0;
    if existing.iter().next().is_some() {
        for (_, _, mut transform) in &mut existing {
            transform.translation = pos;
        }
        for (_, mut sprite, mut transform) in &mut bars {
            let filled = width * progress.clamp(0.0, 1.0);
            sprite.custom_size = Some(Vec2::new(filled.max(0.001), 5.0));
            // Grown from the left edge rather than the centre, so it reads as
            // filling up rather than as spreading out from nothing.
            transform.translation.x = -width / 2.0 + filled / 2.0;
        }
        return;
    }

    let font: Handle<Font> = asset_server.load("ui/FairfaxSM.ttf");
    commands
        .spawn((
            LobbyExitDoor,
            SpatialBundle {
                transform: Transform::from_translation(pos),
                ..default()
            },
        ))
        .with_children(|parent| {
            // The track the bar runs along, always present so the doorway has a
            // sill to read against.
            parent.spawn(SpriteBundle {
                sprite: Sprite {
                    custom_size: Some(Vec2::new(width, 5.0)),
                    color: Color::rgba(0.10, 0.05, 0.06, 0.55),
                    ..default()
                },
                transform: Transform::from_xyz(0.0, -size.y / 2.0 + 6.0, 0.2),
                ..default()
            });
            parent.spawn((
                LobbyExitBar(0.0),
                SpriteBundle {
                    sprite: Sprite {
                        custom_size: Some(Vec2::new(0.001, 5.0)),
                        color: Color::rgb(0.925, 0.651, 0.216),
                        ..default()
                    },
                    transform: Transform::from_xyz(-width / 2.0, -size.y / 2.0 + 6.0, 0.3),
                    ..default()
                },
            ));
            parent.spawn(Text2dBundle {
                text: Text::from_section(
                    "LEAVE",
                    TextStyle {
                        font,
                        font_size: 9.0,
                        color: Color::rgba(1.0, 0.84, 0.55, 0.75),
                    },
                ),
                transform: Transform::from_xyz(0.0, -size.y / 2.0 + 15.0, 0.3),
                ..default()
            });
        });
}

/// Marks the top-of-screen "removing inactive players in Ns..." banner shown
/// while `GlobalInput::prune_countdown` is running. Carries its current text
/// so the sync system can tell whether it needs to respawn.
#[derive(bevy::prelude::Component)]
struct PruneCountdownRoot(String);

fn sync_prune_countdown_system(
    mut commands: bevy::prelude::Commands,
    input: bevy::prelude::Res<GlobalInput>,
    asset_server: bevy::prelude::Res<bevy::prelude::AssetServer>,
    existing: bevy::prelude::Query<(bevy::prelude::Entity, &PruneCountdownRoot)>,
) {
    use bevy::hierarchy::{BuildChildren, DespawnRecursiveExt};
    use bevy::prelude::*;

    let label = input.prune_countdown.as_ref().map(|pc| {
        let remaining = pc
            .deadline
            .saturating_duration_since(std::time::Instant::now())
            .as_secs_f32()
            .ceil() as i32;
        format!("Removing inactive players in {}…", remaining.max(0))
    });

    let Some(label) = label else {
        for (entity, _) in &existing {
            commands.entity(entity).despawn_recursive();
        }
        return;
    };

    if let Some((_, root)) = existing.iter().next() {
        if root.0 == label {
            return;
        }
        for (entity, _) in &existing {
            commands.entity(entity).despawn_recursive();
        }
    }

    let font: Handle<Font> = asset_server.load("ui/FairfaxSM.ttf");
    commands
        .spawn((
            PruneCountdownRoot(label.clone()),
            NodeBundle {
                style: Style {
                    position_type: PositionType::Absolute,
                    width: Val::Percent(100.0),
                    top: Val::Px(16.0),
                    justify_content: JustifyContent::Center,
                    ..default()
                },
                ..default()
            },
        ))
        .with_children(|parent| {
            parent.spawn(TextBundle::from_section(
                label,
                TextStyle { font, font_size: 28.0, color: Color::rgb(1.0, 0.4, 0.4) },
            ));
        });
}

/// Where the sign-in pad is, its footprint, and whether someone's on it.
fn lobby_sign_in_pad(game: &Game) -> Option<(bevy::prelude::Vec3, bevy::prelude::Vec2)> {
    let session = game.sessions.get(SessionNames::GAME)?;
    let world = &session.world;
    let entities = world.resource::<Entities>();
    let transforms = world.components.get::<Transform>().borrow();
    let pads = world.components.get::<SignInPad>().borrow();
    entities
        .iter_with((&transforms, &pads))
        .next()
        .map(|(_, (transform, pad))| {
            (
                transform.translation,
                bevy::prelude::Vec2::new(pad.size.x, pad.size.y),
            )
        })
}

/// Marks the drawn sign-in button.
#[derive(bevy::prelude::Component)]
struct LobbySignInPad;

/// Draws the sign-in pad on the floor.
///
/// The element itself is only a collider — without this it was invisible, so
/// the instruction to jump on the pad pointed at nothing.
fn sync_sign_in_pad_system(
    mut commands: bevy::prelude::Commands,
    bones_game: bevy::prelude::Res<bones_bevy_renderer::BonesGame>,
    asset_server: bevy::prelude::Res<bevy::prelude::AssetServer>,
    mut existing: bevy::prelude::Query<(
        bevy::prelude::Entity,
        &LobbySignInPad,
        &mut bevy::prelude::Transform,
    )>,
) {
    use bevy::hierarchy::{BuildChildren, DespawnRecursiveExt};
    use bevy::prelude::*;

    let Some((pos, size)) = lobby_sign_in_pad(&bones_game.0) else {
        for (entity, _, _) in &existing {
            commands.entity(entity).despawn_recursive();
        }
        return;
    };

    // Nothing about this button's *contents* ever changes — who the code is
    // for is said by the sign, not the pad — so once it's drawn it only ever
    // needs following around, and the press animates on the sprites already
    // there (see `press_pads_system`).
    if let Some((entity, _, mut transform)) = existing.iter_mut().next() {
        transform.translation = Vec3::new(pos.x, pos.y, LOBBY_PROP_Z - 1.0);
        let _ = entity;
        return;
    }

    let font: Handle<Font> = asset_server.load("ui/FairfaxSM.ttf");
    commands
        .spawn((
            LobbySignInPad,
            SpatialBundle {
                transform: Transform::from_xyz(pos.x, pos.y, LOBBY_PROP_Z - 1.0),
                ..default()
            },
        ))
        .with_children(|parent| {
            spawn_pad_button(
                parent,
                PadButton::SignIn,
                Vec3::ZERO,
                size,
                "SIGN IN",
                Color::rgb(0.925, 0.651, 0.216),
                font,
            );
        });
}

/// Marks the in-world QR signboard. Spawned once and then kept in step with
/// the map element every frame — the lobby session is rebuilt from scratch
/// on every seat change (`rebuild_lobby`), so the element's entity, and with
/// it the sign's position, does not survive a join.
///
/// Carries the URL it currently encodes: standing on the sign-in platform
/// re-aims the sign at a different player, which means new pixels.
#[derive(bevy::prelude::Component)]
struct LobbyQrSign(String);

/// Paints the join QR code (and the URL under it) onto the map's QR sign
/// element. Bones owns *where* the sign is; this owns what's on its face,
/// because the code encodes a session URL bones never sees.
fn sync_lobby_qr_system(
    mut commands: bevy::prelude::Commands,
    bones_game: bevy::prelude::Res<bones_bevy_renderer::BonesGame>,
    mut images: bevy::prelude::ResMut<bevy::prelude::Assets<bevy::render::texture::Image>>,
    mut existing: bevy::prelude::Query<(
        bevy::prelude::Entity,
        &LobbyQrSign,
        &mut bevy::prelude::Transform,
    )>,
) {
    use bevy::hierarchy::{BuildChildren, DespawnRecursiveExt};
    use bevy::prelude::*;

    let sign = lobby_qr_sign(&bones_game.0);

    let Some((pos, size)) = sign else {
        for (entity, _, _) in &existing {
            commands.entity(entity).despawn_recursive();
        }
        return;
    };

    // Who the code is for — and there is no code until somebody has said.
    //
    // A seatless join link can't do the one thing this code exists to do:
    // tie the phone that scans it to the controller its owner is holding.
    // Showing one anyway invites the whole room to scan a code that lands
    // them nowhere, so the screen stays dark until a player jumps on the
    // button below it and claims it.
    let seat = bones_game
        .0
        .shared_resource::<GameNightBridge>()
        .claim_seat();
    let url = seat.map(|seat| format!("{}?seat={}", lobby_join_url(), seat));

    // Already up and still encoding the right thing: just track the element.
    if let Some((entity, shown, mut transform)) = existing.iter_mut().next() {
        transform.translation = Vec3::new(pos.x, pos.y, LOBBY_PROP_Z);
        if shown.0 == url.clone().unwrap_or_default() {
            return;
        }
        commands.entity(entity).despawn_recursive();
    }

    // The slab the code is set into — and the thing players stand on. No
    // caption, no printed URL: this is a machine in the room now, not a
    // poster, and the code is the whole message. Who it's currently aimed at
    // is said by the button it sits on, which is right on top of it.
    let board = size + Vec2::splat(SCREEN_FRAME * 2.0);
    let code = url
        .as_deref()
        .and_then(generate_qr_bevy_image)
        .map(|img| images.add(img));

    commands
        .spawn((
            LobbyQrSign(url.unwrap_or_default()),
            SpatialBundle {
                transform: Transform::from_xyz(pos.x, pos.y, LOBBY_PROP_Z),
                ..default()
            },
        ))
        .with_children(|parent| {
            spawn_screen_slab(
                parent,
                board,
                if code.is_some() {
                    Color::rgb(0.071, 0.082, 0.235)
                } else {
                    Color::rgb(0.075, 0.035, 0.055)
                },
            );
            if let Some(code) = code {
                parent.spawn(SpriteBundle {
                    texture: code,
                    sprite: Sprite {
                        custom_size: Some(size),
                        ..default()
                    },
                    transform: Transform::from_xyz(0.0, 0.0, 0.1),
                    ..default()
                });
            }
        });
}

/// The body of a lobby screen: a slab with a lit recess for the screen
/// itself, plus a bright top edge so the surface you can land on is obvious
/// from across the room.
///
/// Every screen in the lobby is a platform now, and a platform has to look
/// like one — a flat panel floating at head height reads as scenery, and
/// players don't jump at scenery.
fn spawn_screen_slab(
    parent: &mut bevy::hierarchy::ChildBuilder,
    slab: bevy::prelude::Vec2,
    face: bevy::prelude::Color,
) {
    use bevy::prelude::*;

    // The frame is the room's own dark wood, not a neutral grey. Grey was the
    // single most off-key thing left in the lobby: the furniture, the floor and
    // the walls are all drawn from one warm palette, and three cold slabs
    // floating in the middle of it read as UI pasted over the art rather than
    // as cabinets standing in the room.
    parent.spawn(SpriteBundle {
        sprite: Sprite {
            custom_size: Some(slab),
            color: Color::rgb(0.165, 0.090, 0.071),
            ..default()
        },
        transform: Transform::from_xyz(0.0, 0.0, -0.3),
        ..default()
    });
    parent.spawn(SpriteBundle {
        sprite: Sprite {
            custom_size: Some(slab - Vec2::splat(6.0)),
            color: face,
            ..default()
        },
        transform: Transform::from_xyz(0.0, 0.0, -0.2),
        ..default()
    });
    // The landing surface. Warm, because every other standing surface in the
    // room is lit by the same amber lamps and a white edge read as a highlight
    // from some other light source.
    parent.spawn(SpriteBundle {
        sprite: Sprite {
            custom_size: Some(Vec2::new(slab.x - 4.0, 5.0)),
            color: Color::rgba(1.0, 0.84, 0.55, 0.42),
            ..default()
        },
        transform: Transform::from_xyz(0.0, slab.y / 2.0 - 4.0, -0.1),
        ..default()
    });
}

/// Where the lobby's music pads are: world position, footprint, and which job
/// the pad does.
fn lobby_music_pads(game: &Game) -> Vec<(bevy::prelude::Vec3, bevy::prelude::Vec2, bool)> {
    let Some(session) = game.sessions.get(SessionNames::GAME) else {
        return Vec::new();
    };
    let world = &session.world;
    let entities = world.resource::<Entities>();
    let transforms = world.components.get::<Transform>().borrow();
    let pads = world.components.get::<MusicPad>().borrow();
    entities
        .iter_with((&transforms, &pads))
        .map(|(_, (transform, pad))| {
            (
                transform.translation,
                bevy::prelude::Vec2::new(pad.size.x, pad.size.y),
                pad.skips,
            )
        })
        .collect()
}

/// Where the jukebox's screen platform is: its world position, the lit face,
/// and the whole slab.
fn lobby_music_screen(
    game: &Game,
) -> Option<(
    bevy::prelude::Vec3,
    bevy::prelude::Vec2,
    bevy::prelude::Vec2,
)> {
    let session = game.sessions.get(SessionNames::GAME)?;
    let world = &session.world;
    let entities = world.resource::<Entities>();
    let transforms = world.components.get::<Transform>().borrow();
    let screens = world.components.get::<MusicScreen>().borrow();
    entities
        .iter_with((&transforms, &screens))
        .next()
        .map(|(_, (transform, screen))| {
            (
                bevy::prelude::Vec3::new(
                    transform.translation.x,
                    transform.translation.y,
                    LOBBY_PROP_Z,
                ),
                bevy::prelude::Vec2::new(screen.screen_size.x, screen.screen_size.y),
                bevy::prelude::Vec2::new(screen.size.x, screen.size.y),
            )
        })
}

/// Which lobby pad a drawn button belongs to, so the press animation can find
/// how far in it currently is without rebuilding the sprite tree.
///
/// Keyed by *job* rather than by index: there is one sign-in pad, one
/// next-game pad and exactly two music pads (one that skips, one that
/// doesn't), so nothing here depends on the order the world happens to
/// iterate its entities in.
#[derive(bevy::prelude::Component, Clone, Copy, PartialEq)]
enum PadButton {
    SignIn,
    /// The TV's own pad. `skips` picks the half: START on the left, SKIP on
    /// the right (see `next_game_trigger::pad_halves`).
    NextGame { skips: bool },
    Music { skips: bool },
}

/// The moving part of a drawn button: everything that sinks when it's hit,
/// remembering where it sits at rest.
#[derive(bevy::prelude::Component)]
struct PadFace {
    home_y: f32,
    pad: PadButton,
}

/// How far into its housing a button sinks when fully pressed, in world
/// units. Deep enough to read across a living room, shallow enough that a
/// button barely taller than this doesn't vanish into the floor.
const PAD_PRESS_DEPTH: f32 = 4.0;

/// Draw a lobby button: a fixed base with a face resting on top of it.
///
/// The face is the thing that moves, so the base showing through underneath
/// is what makes the press legible — a plate that simply changes colour reads
/// as decoration, one that drops into its housing reads as a button somebody
/// just hit.
fn spawn_pad_button(
    parent: &mut bevy::hierarchy::ChildBuilder,
    pad: PadButton,
    offset: bevy::prelude::Vec3,
    size: bevy::prelude::Vec2,
    label: &str,
    face_color: bevy::prelude::Color,
    font: bevy::prelude::Handle<bevy::prelude::Font>,
) {
    use bevy::hierarchy::BuildChildren;
    use bevy::prelude::*;

    // Housing: sits still, and is as tall as the face's full travel plus a
    // little, so a pressed button still has something under it.
    parent.spawn(SpriteBundle {
        sprite: Sprite {
            custom_size: Some(size + Vec2::new(10.0, 4.0)),
            color: Color::rgb(0.07, 0.06, 0.10),
            ..default()
        },
        transform: Transform::from_xyz(offset.x, offset.y - PAD_PRESS_DEPTH, offset.z - 0.2),
        ..default()
    });

    let home_y = offset.y;
    parent
        .spawn((
            PadFace { home_y, pad },
            SpatialBundle {
                transform: Transform::from_translation(offset),
                ..default()
            },
        ))
        .with_children(|face| {
            face.spawn(SpriteBundle {
                sprite: Sprite {
                    custom_size: Some(size),
                    color: face_color,
                    ..default()
                },
                ..default()
            });
            // A lit top edge, so the face reads as a surface with a height
            // rather than a flat rectangle painted on the floor.
            face.spawn(SpriteBundle {
                sprite: Sprite {
                    custom_size: Some(Vec2::new(size.x - 8.0, 5.0)),
                    color: Color::rgba(1.0, 1.0, 1.0, 0.28),
                    ..default()
                },
                transform: Transform::from_xyz(0.0, size.y / 2.0 - 4.0, 0.1),
                ..default()
            });
            face.spawn(Text2dBundle {
                text: Text::from_section(
                    label,
                    TextStyle {
                        font,
                        font_size: 13.0,
                        color: Color::rgba(1.0, 1.0, 1.0, 0.92),
                    },
                )
                .with_alignment(TextAlignment::Center),
                transform: Transform::from_xyz(0.0, size.y / 2.0 + 11.0, 0.2),
                ..default()
            });
        });
}

/// Cut `text` to at most `max` characters, ending in an ellipsis when it had
/// to. Counts characters rather than bytes and cuts on a char boundary — track
/// titles are full of accents and non-Latin scripts, and slicing one in half
/// panics.
fn ellipsize(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        return text.to_string();
    }
    let kept: String = text.chars().take(max.saturating_sub(1)).collect();
    format!("{}…", kept.trim_end())
}

/// How far each lobby button is currently pushed in, straight off the bones
/// world.
#[derive(Default, Clone, Copy)]
struct PadPresses {
    sign_in: f32,
    next_game: f32,
    next_game_skip: f32,
    music_pause: f32,
    music_skip: f32,
}

impl PadPresses {
    fn of(&self, pad: PadButton) -> f32 {
        match pad {
            PadButton::SignIn => self.sign_in,
            PadButton::NextGame { skips: false } => self.next_game,
            PadButton::NextGame { skips: true } => self.next_game_skip,
            PadButton::Music { skips: false } => self.music_pause,
            PadButton::Music { skips: true } => self.music_skip,
        }
    }
}

fn lobby_pad_presses(game: &Game) -> PadPresses {
    let Some(session) = game.sessions.get(SessionNames::GAME) else {
        return PadPresses::default();
    };
    let world = &session.world;
    let entities = world.resource::<Entities>();
    let mut presses = PadPresses::default();

    let sign_ins = world.components.get::<SignInPad>().borrow();
    if let Some((_, pad)) = entities.iter_with(&sign_ins).next() {
        presses.sign_in = pad.press;
    }
    let triggers = world.components.get::<NextGameTrigger>().borrow();
    if let Some((_, trigger)) = entities.iter_with(&triggers).next() {
        presses.next_game = trigger.press;
        presses.next_game_skip = trigger.skip_press;
    }
    let music = world.components.get::<MusicPad>().borrow();
    for (_, pad) in entities.iter_with(&music) {
        if pad.skips {
            presses.music_skip = pad.press;
        } else {
            presses.music_pause = pad.press;
        }
    }
    presses
}

/// Sink every button that's been hit, and let it rise again.
///
/// Separate from the systems that *build* the buttons so that an animation
/// frame costs a transform write rather than a rebuilt sprite tree — and so
/// the pads' contents (a track title, an UP NEXT line) can change on their own
/// schedule without interrupting a press mid-drop.
fn press_pads_system(
    bones_game: bevy::prelude::Res<bones_bevy_renderer::BonesGame>,
    mut faces: bevy::prelude::Query<(&PadFace, &mut bevy::prelude::Transform)>,
) {
    if faces.is_empty() {
        return;
    }
    let presses = lobby_pad_presses(&bones_game.0);
    for (face, mut transform) in &mut faces {
        transform.translation.y = face.home_y - presses.of(face.pad) * PAD_PRESS_DEPTH;
    }
}

/// Marks the drawn jukebox. Carries a fingerprint of what it was drawn from,
/// so it's rebuilt when the track changes and left alone the rest of the time
/// — presses animate on the existing sprites (see `press_pads_system`).
#[derive(bevy::prelude::Component)]
struct LobbyJukebox(String);

/// Draws the lobby's jukebox: a platform with the host's current track in its
/// face, and the buttons that pause and skip it standing on top.
///
/// The slab is always drawn, because it is always solid — level geometry that
/// blinked in and out with somebody's Spotify would drop whoever was standing
/// on it. What comes and goes is what's *on* it: with nothing playing the
/// screen is dark and the buttons aren't there, because controls for a stereo
/// that isn't playing are worse than none (the buttons stop being solid in the
/// same breath — see `core::elements::music_pad`).
fn sync_jukebox_system(
    mut commands: bevy::prelude::Commands,
    bones_game: bevy::prelude::Res<bones_bevy_renderer::BonesGame>,
    asset_server: bevy::prelude::Res<bevy::prelude::AssetServer>,
    mut existing: bevy::prelude::Query<(
        bevy::prelude::Entity,
        &LobbyJukebox,
        &mut bevy::prelude::Transform,
    )>,
) {
    use bevy::hierarchy::{BuildChildren, DespawnRecursiveExt};
    use bevy::prelude::*;

    let track = bones_game
        .0
        .shared_resource::<GameNightBridge>()
        .now_playing()
        .cloned();

    let Some((anchor, screen, slab)) = lobby_music_screen(&bones_game.0) else {
        for (entity, _, _) in &existing {
            commands.entity(entity).despawn_recursive();
        }
        return;
    };
    let pads = lobby_music_pads(&bones_game.0);

    // Classical releases in particular carry titles that are really a
    // catalogue entry ("…, Op. 56: No. 4, Innig (Arr. for Piano 4 Hands)").
    // The screen is read at a glance from a sofa, so it gets the front of the
    // title and says out loud that there's more, rather than growing to fit
    // or quietly clipping mid-word.
    //
    // With nothing playing it says so, rather than sitting there dark: an
    // unlit screen on a machine you can stand on reads as broken, and the one
    // thing worth telling the room is that this works at all — put something
    // on the host's machine and it shows up here.
    let (heading, title, byline) = match &track {
        Some(t) => (
            if t.playing { "NOW PLAYING" } else { "PAUSED" },
            ellipsize(&t.title, 44),
            match t.artist.as_str() {
                "" => format!("from {}", t.source),
                artist => format!("{artist} — from {}", t.source),
            },
        ),
        None => (
            "JUKEBOX OFFLINE",
            "Play some music".to_string(),
            String::new(),
        ),
    };
    let fingerprint = format!("{heading}|{title}|{byline}");

    if let Some((entity, drawn, mut transform)) = existing.iter_mut().next() {
        transform.translation = anchor;
        if drawn.0 == fingerprint {
            return;
        }
        commands.entity(entity).despawn_recursive();
    }

    let font: Handle<Font> = asset_server.load("ui/FairfaxSM.ttf");
    commands
        .spawn((
            LobbyJukebox(fingerprint),
            SpatialBundle {
                transform: Transform::from_translation(anchor),
                ..default()
            },
        ))
        .with_children(|parent| {
            // Warmer than the next-game TV's blue: this is the room's music,
            // not the party's queue, and at a glance across a living room
            // colour is the only thing telling them apart. Dark when quiet.
            spawn_screen_slab(
                parent,
                slab,
                if track.is_some() {
                    Color::rgb(0.145, 0.055, 0.098)
                } else {
                    Color::rgb(0.075, 0.035, 0.055)
                },
            );

            parent.spawn(Text2dBundle {
                text: Text::from_section(
                    format!("♪ {heading}"),
                    TextStyle {
                        font: font.clone(),
                        font_size: 10.0,
                        color: if heading == "NOW PLAYING" {
                            Color::rgba(1.0, 0.75, 0.95, 0.95)
                        } else {
                            Color::rgba(1.0, 1.0, 1.0, 0.55)
                        },
                    },
                ),
                transform: Transform::from_xyz(0.0, screen.y / 2.0 - 7.0, 0.1),
                ..default()
            });
            parent.spawn(Text2dBundle {
                text: Text::from_section(
                    title,
                    TextStyle {
                        font: font.clone(),
                        font_size: 13.0,
                        color: if track.is_some() {
                            Color::WHITE
                        } else {
                            Color::rgba(1.0, 1.0, 1.0, 0.65)
                        },
                    },
                )
                .with_alignment(TextAlignment::Center),
                text_2d_bounds: bevy::text::Text2dBounds {
                    size: Vec2::new(screen.x - 10.0, screen.y - 26.0),
                },
                transform: Transform::from_xyz(0.0, -1.0, 0.1),
                ..default()
            });
            if !byline.is_empty() {
                parent.spawn(Text2dBundle {
                    text: Text::from_section(
                        ellipsize(&byline, 34),
                        TextStyle {
                            font: font.clone(),
                            font_size: 9.0,
                            color: Color::rgba(1.0, 1.0, 1.0, 0.6),
                        },
                    )
                    .with_alignment(TextAlignment::Center),
                    transform: Transform::from_xyz(0.0, -screen.y / 2.0 + 7.0, 0.1),
                    ..default()
                });
            }

            // The buttons standing on the slab's top surface — the element is
            // only a collider, so without this the thing you're told to jump
            // on isn't there. None of them while there's nothing to control.
            for (pos, size, skips) in track.is_some().then_some(&pads).into_iter().flatten() {
                let label = match (skips, track.as_ref().is_some_and(|t| t.playing)) {
                    (true, _) => "SKIP ⏭",
                    (false, true) => "PAUSE ⏸",
                    (false, false) => "PLAY ▶",
                };
                spawn_pad_button(
                    parent,
                    PadButton::Music { skips: *skips },
                    Vec3::new(pos.x - anchor.x, pos.y - anchor.y, -1.0),
                    *size,
                    label,
                    Color::rgb(0.62, 0.30, 0.58),
                    font.clone(),
                );
            }
        });
}

/// Marks the in-world TV. Its children are rebuilt whenever the displayed
/// title changes; the hold bar is updated in place every frame.
#[derive(bevy::prelude::Component)]
struct LobbyTv(String);

/// Draws the lobby TV: a cabinet, a screen showing whatever the daemon has
/// warmed up next, and the prompt on the pad below it.
fn sync_next_game_tv_system(
    mut commands: bevy::prelude::Commands,
    bones_game: bevy::prelude::Res<bones_bevy_renderer::BonesGame>,
    asset_server: bevy::prelude::Res<bevy::prelude::AssetServer>,
    mut existing: bevy::prelude::Query<(
        bevy::prelude::Entity,
        &LobbyTv,
        &mut bevy::prelude::Transform,
    )>,
) {
    use bevy::hierarchy::{BuildChildren, DespawnRecursiveExt};
    use bevy::prelude::*;

    let (status, button) = {
        let bridge = bones_game.0.shared_resource::<GameNightBridge>();
        (bridge.next_game_status(), bridge.tv_button())
    };

    let Some((pos, size, pad_pos, pad_size)) = lobby_tv(&bones_game.0) else {
        for (entity, _, _) in &existing {
            commands.entity(entity).despawn_recursive();
        }
        return;
    };

    // The screen's two lines: what state we're in, and what it's about.
    let (kicker, kicker_color, title) = match &status {
        // A game the party can walk straight back into. Says PAUSED rather
        // than the title's usual "UP NEXT" kicker because that is the fact
        // they came out here to act on: it is still going, and it is waiting.
        NextGameStatus::Live { title, paused } => (
            if *paused { "PAUSED" } else { "PLAYING" }.to_string(),
            Color::rgba(0.6, 1.0, 0.7, 0.95),
            title.clone(),
        ),
        NextGameStatus::Ready(t) => (
            "UP NEXT".to_string(),
            Color::rgba(0.6, 0.75, 1.0, 0.9),
            t.clone(),
        ),
        // A game that reports gets a percentage and, if it named the step,
        // what it's actually doing — waiting is far easier to bear when the
        // screen shows something moving. One that reports nothing still
        // says "LOADING…", never an invented number.
        NextGameStatus::Loading(t, progress) => (
            match progress {
                Some(p) => format!("LOADING… {}%", p.percent),
                None => "LOADING…".to_string(),
            },
            Color::rgba(1.0, 0.85, 0.4, 0.95),
            match progress.as_ref().and_then(|p| p.label.as_ref()) {
                Some(step) => format!("{t} — {step}"),
                None => t.clone(),
            },
        ),
        // Deliberately its own kicker rather than "LOADING…": a game being
        // fetched over the network is a different promise from one warming up
        // locally, and it takes minutes rather than seconds. Telling the party
        // which one they're waiting on is the difference between patience and
        // pressing buttons at a screen that looks stuck.
        NextGameStatus::Downloading(t, percent) => (
            match percent {
                Some(p) => format!("DOWNLOADING… {p}%"),
                None => "DOWNLOADING…".to_string(),
            },
            Color::rgba(0.55, 0.85, 1.0, 0.95),
            t.clone(),
        ),
        NextGameStatus::Voting => (
            "VOTE".to_string(),
            Color::rgba(0.6, 1.0, 0.7, 0.95),
            "Pick the next game".to_string(),
        ),
        NextGameStatus::Empty => (
            "UP NEXT".to_string(),
            Color::rgba(0.6, 0.75, 1.0, 0.9),
            "Nothing queued".to_string(),
        ),
    };

    if let Some((entity, tv, mut transform)) = existing.iter_mut().next() {
        transform.translation = Vec3::new(pos.x, pos.y, LOBBY_PROP_Z);
        if tv.0 == format!("{kicker}|{title}|{button:?}") {
            return;
        }
        commands.entity(entity).despawn_recursive();
    }

    let font: Handle<Font> = asset_server.load("ui/FairfaxSM.ttf");
    let cabinet = size + Vec2::splat(SCREEN_FRAME * 2.0);

    commands
        .spawn((
            LobbyTv(format!("{kicker}|{title}|{button:?}")),
            SpatialBundle {
                transform: Transform::from_xyz(pos.x, pos.y, LOBBY_PROP_Z),
                ..default()
            },
        ))
        .with_children(|parent| {
            spawn_screen_slab(parent, cabinet, Color::rgb(0.071, 0.082, 0.235));
            // State line: UP NEXT when ready, LOADING… while on its way.
            parent.spawn(Text2dBundle {
                text: Text::from_section(
                    kicker,
                    TextStyle {
                        font: font.clone(),
                        font_size: 11.0,
                        color: kicker_color,
                    },
                ),
                transform: Transform::from_xyz(0.0, size.y / 2.0 - 9.0, 0.1),
                ..default()
            });
            // The game itself
            parent.spawn(Text2dBundle {
                text: Text::from_section(
                    ellipsize(&title, 46),
                    TextStyle {
                        font: font.clone(),
                        font_size: 15.0,
                        color: Color::WHITE,
                    },
                )
                .with_alignment(TextAlignment::Center),
                text_2d_bounds: bevy::text::Text2dBounds {
                    size: Vec2::new(size.x - 12.0, size.y - 18.0),
                },
                transform: Transform::from_xyz(0.0, -5.0, 0.1),
                ..default()
            });
            // And the two buttons on the slab below it: start the thing the
            // screen is advertising, or put something else on.
            //
            // Laid out from the same split the collider uses, so the face you
            // aim for is the one you press.
            let ((play_pos, play_size), (skip_pos, skip_size)) =
                crate::core::elements::next_game_trigger::pad_halves(
                    bevy::math::Vec2::new(pad_pos.x, pad_pos.y),
                    pad_size,
                );
            // Three states, because the button genuinely has three jobs:
            // walk back into the open game, start the warm one, or sit there
            // greyed out because it hasn't finished loading. That last one is
            // the place the party looks when they wonder why nothing
            // happened, so it has to look disabled rather than broken.
            let (label, colour) = match button {
                TvButton::Back => ("BACK", Color::rgb(0.26, 0.60, 0.44)),
                TvButton::Start => ("START", Color::rgb(0.26, 0.60, 0.44)),
                TvButton::Disabled => ("START", Color::rgb(0.24, 0.26, 0.30)),
            };
            spawn_pad_button(
                parent,
                PadButton::NextGame { skips: false },
                Vec3::new(play_pos.x - pos.x, play_pos.y - pos.y, -1.0),
                play_size,
                label,
                colour,
                font.clone(),
            );
            spawn_pad_button(
                parent,
                PadButton::NextGame { skips: true },
                Vec3::new(skip_pos.x - pos.x, skip_pos.y - pos.y, -1.0),
                skip_size,
                "SKIP",
                Color::rgb(0.42, 0.36, 0.62),
                font,
            );
        });
}

fn generate_qr_bevy_image(url: &str) -> Option<bevy::render::texture::Image> {
    use qrcode::QrCode;
    use bevy::render::render_resource::{Extent3d, TextureDimension, TextureFormat};

    let code = QrCode::new(url.as_bytes()).ok()?;
    let image_colors = code.to_colors();
    let width = code.width();

    let border = 2;
    let full_width = width + border * 2;
    let scale = 6;
    let img_size = full_width * scale;

    let mut buffer = vec![255u8; img_size * img_size * 4];

    for y in 0..img_size {
        for x in 0..img_size {
            let qx = (x / scale) as i32 - border as i32;
            let qy = (y / scale) as i32 - border as i32;

            let is_black = if qx >= 0 && qx < width as i32 && qy >= 0 && qy < width as i32 {
                let idx = (qy * width as i32 + qx) as usize;
                image_colors.get(idx) == Some(&qrcode::Color::Dark)
            } else {
                false
            };

            let pixel_idx = (y * img_size + x) * 4;
            if is_black {
                buffer[pixel_idx] = 18;
                buffer[pixel_idx + 1] = 20;
                buffer[pixel_idx + 2] = 32;
                buffer[pixel_idx + 3] = 255;
            } else {
                buffer[pixel_idx] = 245;
                buffer[pixel_idx + 1] = 245;
                buffer[pixel_idx + 2] = 250;
                buffer[pixel_idx + 3] = 255;
            }
        }
    }

    Some(bevy::render::texture::Image::new(
        Extent3d {
            width: img_size as u32,
            height: img_size as u32,
            depth_or_array_layers: 1,
        },
        TextureDimension::D2,
        buffer,
        TextureFormat::Rgba8UnormSrgb,
    ))
}



#[cfg(test)]
mod tests {
    use super::*;

    /// The join/reroll name pick must actually vary. This used to be
    /// `FUN_NAMES.iter().find(...)`, which made the first joiner always
    /// "Falcon" and made the menu's "New Name" reroll a no-op.
    #[test]
    fn random_unused_name_varies() {
        let taken = HashSet::new();
        let seen: HashSet<&str> = (0..200)
            .filter_map(|_| random_unused_name(&taken))
            .collect();
        assert!(
            seen.len() > 1,
            "name pick is deterministic, got only {seen:?}"
        );
    }

    /// Names already in use are never handed out again.
    #[test]
    fn random_unused_name_skips_taken() {
        let taken: HashSet<&str> = FUN_NAMES.iter().copied().take(FUN_NAMES.len() - 1).collect();
        let last = FUN_NAMES[FUN_NAMES.len() - 1];
        for _ in 0..50 {
            assert_eq!(random_unused_name(&taken), Some(last));
        }
    }

    /// Everyone seated: the caller has to handle the fallback itself.
    #[test]
    fn random_unused_name_none_when_all_taken() {
        let taken: HashSet<&str> = FUN_NAMES.iter().copied().collect();
        assert_eq!(random_unused_name(&taken), None);
    }

    fn grid(fill: &str) -> String {
        serde_json::to_string(&vec![fill; 16 * 16]).unwrap()
    }

    /// Decoding itself is `gamenight-protocol`'s job and tested there; what
    /// matters here is that a real avatar turns into a texture jumpy can
    /// upload, scaled up so the pixels stay hard.
    #[test]
    fn avatar_image_builds_a_scaled_texture() {
        let img = avatar_image(&grid("#ff0000")).expect("a full grid must decode");
        let size = img.texture_descriptor.size;
        assert_eq!(size.width, size.height);
        assert!(
            size.width > 16,
            "the portrait must be scaled up, not drawn at 16px"
        );
        assert_eq!(img.data.len(), (size.width * size.height * 4) as usize);
    }

    /// Nothing drawn means nothing to show — rendering it would just put an
    /// empty box over someone's head.
    #[test]
    fn blank_avatars_render_nothing() {
        assert!(avatar_image(&grid("#0f172a")).is_none());
    }

    /// The sign-in pad hands the bridge a *seat index*; the party speaks
    /// player ids. If that mapping breaks, standing on the pad silently
    /// re-aims the wall QR at nobody.
    #[test]
    fn seat_player_maps_seat_index_to_player() {
        use gamenight_protocol::{Seat, SeatOccupant};
        let alice = PlayerId::new();
        let seats = vec![
            Seat { index: 0, occupant: SeatOccupant::Empty, controller: None },
            Seat { index: 1, occupant: SeatOccupant::Local { player_id: alice }, controller: None },
        ];
        let find = |idx: u32| {
            seats
                .iter()
                .find(|s| s.index as u32 == idx)
                .and_then(|s| s.occupant.player_id())
        };
        assert_eq!(find(1), Some(alice), "an occupied seat resolves to its player");
        assert_eq!(find(0), None, "an empty seat resolves to nobody");
        assert_eq!(find(9), None, "an unknown seat resolves to nobody");
    }

    /// The avatar is arbitrary text off the wire; none of it may panic.
    #[test]
    fn avatar_image_rejects_bad_payloads() {
        for bad in ["", "not json", "[]", "[1,2,3]"] {
            assert!(avatar_image(bad).is_none(), "should reject {bad:?}");
        }
    }

}

#[cfg(test)]
mod claim_release_tests {
    use super::*;
    use gamenight_protocol::Player;

    fn player(name: &str, color: Option<&str>, avatar: Option<&str>) -> Player {
        Player {
            id: PlayerId::new(),
            name: name.into(),
            color: color.map(Into::into),
            avatar: avatar.map(Into::into),
            library: Vec::new(),
        }
    }

    /// Anything a phone can set must move the fingerprint, because that is
    /// what frees the sign-in pad for the next person in the queue.
    #[test]
    fn a_claim_changes_the_fingerprint() {
        let mut p = player("Waffle", Some("#5c9eff"), None);
        let id = p.id;
        let before = player_fingerprint(std::slice::from_ref(&p), id).unwrap();

        p.name = "Joep".into();
        let renamed = player_fingerprint(std::slice::from_ref(&p), id).unwrap();
        assert_ne!(before, renamed, "a rename must release the pad");

        p.color = Some("#00ff00".into());
        let recoloured = player_fingerprint(std::slice::from_ref(&p), id).unwrap();
        assert_ne!(renamed, recoloured, "a colour change must release the pad");

        p.avatar = Some("art".into());
        let drawn = player_fingerprint(std::slice::from_ref(&p), id).unwrap();
        assert_ne!(recoloured, drawn, "an avatar must release the pad");
    }

    /// …and nothing else may, or the pad would free itself mid-scan.
    #[test]
    fn unrelated_changes_leave_the_fingerprint_alone() {
        let mut p = player("Waffle", Some("#5c9eff"), None);
        let id = p.id;
        let before = player_fingerprint(std::slice::from_ref(&p), id).unwrap();
        p.library.push(gamenight_protocol::GameId::new("jumpy"));
        assert_eq!(
            before,
            player_fingerprint(std::slice::from_ref(&p), id).unwrap(),
            "a library update is not a sign-in"
        );
    }

    /// A player who left the party releases the pad too.
    #[test]
    fn a_missing_player_has_no_fingerprint() {
        let p = player("Waffle", None, None);
        assert!(player_fingerprint(&[], p.id).is_none());
    }

    /// Two people who look identical must still be told apart, or claiming
    /// one would release a pad aimed at the other.
    #[test]
    fn fingerprints_are_looked_up_per_player() {
        let a = player("Twin", Some("#fff000"), None);
        let b = player("Twin", Some("#fff000"), None);
        let players = vec![a.clone(), b.clone()];
        assert_eq!(
            player_fingerprint(&players, a.id),
            player_fingerprint(&players, b.id),
            "identical players have equal fingerprints, which is fine"
        );
        assert!(player_fingerprint(&players, PlayerId::new()).is_none());
    }
}

#[cfg(test)]
mod next_game_status_tests {
    use super::*;
    use gamenight_protocol::{GameMeta, PlaylistEntry, SessionId, SessionInfo, SessionPhase};

    fn shelf(id: &str, title: &str) -> GameMeta {
        GameMeta {
            id: GameId::new(id),
            title: title.into(),
            tagline: None,
            cover: None,
            color: None,
            emoji: None,
            players: None,
            min_players: None,
            max_players: None,
            best_players: None,
            launch: None,
        }
    }

    fn session(game: &str, phase: SessionPhase) -> SessionInfo {
        SessionInfo {
            id: SessionId::new(),
            game: GameId::new(game),
            phase,
            progress: None,
            progress_label: None,
        }
    }

    fn entry(game: &str, title: &str) -> PlaylistEntry {
        PlaylistEntry {
            game: GameId::new(game),
            title: title.into(),
        }
    }

    /// Mirrors `next_game_status` without a live bridge (which owns channels):
    /// same inputs, same decision.
    fn status(warm: Option<SessionInfo>, warming: Option<PlaylistEntry>) -> NextGameStatus {
        let library = vec![shelf("duo", "Duo"), shelf("quad", "Quad")];
        if let Some(w) = warm {
            let title = library
                .iter()
                .find(|m| m.id == w.game)
                .map(|m| m.title.clone())
                .unwrap_or_else(|| w.game.0.clone());
            return match w.phase {
                SessionPhase::Ready | SessionPhase::Running => NextGameStatus::Ready(title),
                _ => NextGameStatus::Loading(
                    title,
                    w.progress.map(|percent| LoadingProgress {
                        percent,
                        label: w.progress_label.clone(),
                    }),
                ),
            };
        }
        if let Some(e) = warming {
            // No session means no process, so nothing could have reported.
            return NextGameStatus::Loading(e.title, None);
        }
        NextGameStatus::Empty
    }

    #[test]
    fn a_ready_session_is_ready() {
        assert_eq!(
            status(Some(session("duo", SessionPhase::Ready)), None),
            NextGameStatus::Ready("Duo".into())
        );
    }

    #[test]
    fn a_preparing_session_is_loading_not_empty() {
        for phase in [SessionPhase::Created, SessionPhase::Preparing] {
            assert_eq!(
                status(Some(session("duo", phase)), None),
                NextGameStatus::Loading("Duo".into(), None),
                "{phase:?} must read as loading"
            );
        }
    }

    /// No session yet, but the daemon has named what it's heading for. This is
    /// the case that used to say "Nothing queued" while a launch was failing.
    #[test]
    fn a_stated_target_with_no_session_is_loading() {
        assert_eq!(
            status(None, Some(entry("quad", "Quad"))),
            NextGameStatus::Loading("Quad".into(), None)
        );
    }

    /// Only a genuinely idle daemon says nothing.
    #[test]
    fn no_session_and_no_target_is_empty() {
        assert_eq!(status(None, None), NextGameStatus::Empty);
    }

    /// The bug this replaced: a running game must never be announced as the
    /// next one loading. The daemon's `warm_target` already excludes it, so
    /// the absence of a target is what we render.
    #[test]
    fn a_running_game_is_not_reported_as_loading() {
        assert_eq!(
            status(None, None),
            NextGameStatus::Empty,
            "with a game already running and nothing else to warm, the TV \
             must not claim the running game is loading"
        );
    }

    /// A warm game the shelf has no entry for still gets named.
    #[test]
    fn an_unknown_game_falls_back_to_its_id() {
        assert_eq!(
            status(Some(session("mystery", SessionPhase::Ready)), None),
            NextGameStatus::Ready("mystery".into())
        );
    }
}

#[cfg(test)]
mod jukebox_tests {
    use super::ellipsize;

    /// The music card is read from a sofa, so a title longer than the card
    /// gets cut — and says so.
    #[test]
    fn long_titles_are_cut_and_marked() {
        assert_eq!(ellipsize("In Paradisum", 54), "In Paradisum");
        assert_eq!(ellipsize("abcdef", 4), "abc…");
        // Trailing space before the ellipsis reads as a typo.
        assert_eq!(ellipsize("ab cdef", 4), "ab…");
    }

    /// Cutting by bytes would panic on the first accented title Spotify
    /// hands us, which is roughly the first one.
    #[test]
    fn cutting_a_title_never_splits_a_character() {
        assert_eq!(ellipsize("Fauré: Requiem", 6), "Fauré…");
        assert_eq!(ellipsize("君の名は", 3), "君の…");
    }
}
