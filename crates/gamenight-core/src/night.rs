//! The GameNight state machine.
//!
//! One struct owns the whole evening: the party (players + seats), the
//! playlist, the active session, the warm session, and the vote board.
//! It is pure — no IO, no clocks, no sockets. The daemon feeds it
//! [`Command`]s and executes the returned [`Effect`]s. That keeps every
//! transition rule unit-testable.

use std::collections::{HashSet, VecDeque};

use gamenight_protocol::{
    GameId, GameMeta, GameSettings, InstallState, InstallStatus, MediaAction, NowPlaying,
    PartySnapshot, Player, PlayerId, PlaylistEntry, Seat, SeatOccupant, SessionId, SessionPhase,
    SettingSpec, SettingValue, VoteOption,
};

use crate::playlist::Playlist;
use crate::session::Session;
use crate::vote::VoteBoard;

/// Everything that can happen to the night, from any source.
#[derive(Debug, Clone, PartialEq)]
pub enum Command {
    /// A game process for this title connected to the daemon.
    GameConnected {
        game: GameId,
    },
    GameDisconnected {
        game: GameId,
    },

    JoinParty {
        name: String,
        /// Preferred seat; falls back to the first free seat if taken.
        seat: Option<u8>,
        color: Option<String>,
        avatar: Option<String>,
        library: Vec<GameId>,
    },
    LeaveParty {
        player_id: PlayerId,
    },
    RenamePlayer {
        player_id: PlayerId,
        name: String,
    },
    SetPlayerColor {
        player_id: PlayerId,
        color: String,
    },
    SetPlayerAvatar {
        player_id: PlayerId,
        avatar: String,
    },
    AssignSeat {
        seat: u8,
        occupant: SeatOccupant,
    },
    /// Two people trade controllers: swap the occupants of these seats.
    SwapSeats {
        a: u8,
        b: u8,
    },
    /// Physical gamepad's ordinal in the host's connected-controller list.
    BindController {
        player_id: PlayerId,
        controller: String,
    },
    SetPlaylist {
        entries: Vec<PlaylistEntry>,
    },
    /// Move an existing entry without interrupting play. Reject stale snapshots.
    MovePlaylistEntry {
        expected: gamenight_protocol::PlaylistSnapshot,
        from: usize,
        to: usize,
    },
    /// Skip to the next game immediately, no vote.
    Next,
    /// Make this game the next one up: warm it now, transition later.
    PlayNext {
        game: GameId,
    },
    Pause,
    Resume,
    /// The party overlay came up: pause the active game.
    OverlayOpened,
    /// The overlay went away: resume, if the overlay was what paused.
    OverlayClosed,
    /// A player reached for this game directly — Cmd+Tab, a Dock click, a
    /// click on its window. See `ClientMessage::RequestStart`: the game
    /// reports what the human did, this decides what it means.
    RequestStart {
        game: GameId,
    },
    Vote {
        player_id: PlayerId,
        option: VoteOption,
    },

    /// The game finished preparing the given session.
    SessionReady {
        session: SessionId,
    },
    /// The match in the given session is over.
    SessionFinished {
        session: SessionId,
    },
    /// The game reported how far along its loading is.
    SessionProgress {
        session: SessionId,
        percent: u8,
        label: Option<String>,
    },

    /// The background installer reported on a game it's fetching. Unlike
    /// `SessionProgress` this doesn't come from a game process — there isn't
    /// one yet — but from the daemon's own downloader.
    InstallProgress {
        status: InstallStatus,
    },

    /// The host's music changed — a new track, a pause, or silence. Comes
    /// from the daemon watching the OS, not from anybody in the party; the
    /// host reaching for their own keyboard arrives here exactly like a pad
    /// press does.
    NowPlaying {
        track: Option<NowPlaying>,
    },
    /// Somebody in the party pressed pause or skip on the music.
    MediaControl {
        action: MediaAction,
    },

    /// A game declared (or re-declared) the match settings it exposes.
    DeclareSettings {
        game: GameId,
        settings: Vec<SettingSpec>,
    },
    /// The party turns a knob. `game` defaults to the active game.
    SetSetting {
        game: Option<GameId>,
        key: String,
        value: SettingValue,
    },
}

/// A lifecycle command the daemon must deliver to a game process.
#[derive(Debug, Clone, PartialEq)]
pub enum GameCommand {
    Prepare {
        seats: Vec<Seat>,
        players: Vec<Player>,
    },
    Start,
    Pause,
    Resume,
    Dispose,
}

/// What the daemon must do after handling a command.
#[derive(Debug, Clone, PartialEq)]
pub enum Effect {
    /// Deliver `command` to the process serving `game`.
    ToGame {
        game: GameId,
        session: SessionId,
        command: GameCommand,
    },
    /// Party state changed; broadcast a fresh snapshot to overlays.
    StateChanged,
    /// The next game needs its process: spawn it per the library's launch
    /// spec. Emitted only for games the library knows how to launch; the
    /// daemon dedupes repeats while a spawn is in flight.
    Launch { game: GameId },
    /// A match-setting value changed (or needs re-hydrating after a
    /// reconnect): deliver it to the process serving `game`, if connected.
    /// Not session-scoped — settings outlive sessions.
    SettingChanged {
        game: GameId,
        key: String,
        value: SettingValue,
    },
    /// Carry out a music command on the host machine. The night keeps no
    /// music state of its own beyond what it was last told is playing — this
    /// is a message to the OS, and the next poll reports what actually
    /// happened.
    MediaControl { action: MediaAction },
    /// The party voted to quit. The night is over.
    PartyOver,
    /// Tell the lobby game whether it currently has the couch's attention.
    /// See `ServerMessage::LobbyFocus`.
    LobbyFocus { game: GameId, active: bool },
    /// The command was rejected; inform the sender only.
    Reject { reason: String },
}

#[derive(Debug)]
pub struct GameNight {
    players: Vec<Player>,
    seats: Vec<Seat>,
    playlist: Playlist,
    connected_games: HashSet<GameId>,
    active: Option<Session>,
    warm: Option<Session>,
    /// The seats the warm session was `prepare`d with. Kept so we can notice
    /// they have gone stale — the party keeps changing while a game warms,
    /// and a session prepared for one player must not be started for two.
    warm_seats: Vec<Seat>,
    active_seats: Vec<Seat>,
    warm_players: Vec<Player>,
    active_players: Vec<Player>,
    // Bounded tombstones for replies already in flight when Dispose is sent.
    retired_sessions: VecDeque<SessionId>,
    history: Vec<GameId>,
    vote: VoteBoard,
    /// A transition has been requested (skip button, vote, finished game) but
    /// could not run yet because the warm session isn't ready.
    pending_transition: bool,
    /// Overrides which playlist entry to warm next (used by Replay).
    next_up: Option<usize>,
    /// The game shelf: presentation metadata for every known title.
    library: Vec<GameMeta>,
    /// Match settings per game, as declared by the games themselves. Values
    /// live here (not in the game) so they survive process reconnects.
    settings: Vec<GameSettings>,
    /// The party overlay is showing (on every screen — server-authoritative).
    overlay_open: bool,
    /// The overlay is what paused the active session, so closing it resumes.
    /// Stays false for explicit pauses, which closing must not undo.
    overlay_paused: bool,
    /// The game that hosts the persistent lobby, if any — see
    /// `set_lobby_game`. Unlike every other title, this one is meant to stay
    /// resident the whole night, so its disconnecting means it actually
    /// crashed, quit, or got restarted, not that a match started elsewhere.
    lobby_game: Option<GameId>,
    /// The lobby's last-notified focus state (see `sync_lobby_focus`) — lets
    /// `LobbyFocus` fire only on actual change instead of every command.
    lobby_focused: bool,
    /// Games the background installer is fetching, newest report last. Kept
    /// keyed by game rather than as a queue: the installer owns the ordering,
    /// this is only the read model of what it's doing.
    installs: Vec<InstallStatus>,
    /// The host's background music, as last reported by the daemon's watcher.
    /// Purely a read model — the music belongs to the OS, and nothing here
    /// decides anything about it.
    now_playing: Option<NowPlaying>,
}

impl Default for GameNight {
    fn default() -> Self {
        Self::new(4)
    }
}

impl GameNight {
    pub fn new(seat_count: u8) -> Self {
        Self {
            players: Vec::new(),
            seats: (0..seat_count)
                .map(|index| Seat {
                    index,
                    occupant: SeatOccupant::Empty,
                    controller: None,
                })
                .collect(),
            playlist: Playlist::default(),
            connected_games: HashSet::new(),
            active: None,
            warm: None,
            warm_seats: Vec::new(),
            active_seats: Vec::new(),
            warm_players: Vec::new(),
            active_players: Vec::new(),
            retired_sessions: VecDeque::new(),
            history: Vec::new(),
            vote: VoteBoard::default(),
            pending_transition: false,
            next_up: None,
            library: Vec::new(),
            settings: Vec::new(),
            overlay_open: false,
            overlay_paused: false,
            lobby_game: None,
            lobby_focused: true,
            installs: Vec::new(),
            now_playing: None,
        }
    }

    /// Declare which game (if any) hosts the persistent lobby. Its
    /// disconnecting resets the party (see `on_game_disconnected`), since
    /// it's meant to stay resident all night — a disconnect means it
    /// crashed, quit, or got restarted, and a fresh lobby process shouldn't
    /// inherit seats occupied by players it never saw join.
    pub fn set_lobby_game(&mut self, game: Option<GameId>) {
        self.lobby_game = game;
    }

    /// Install the game shelf (usually once, at daemon startup).
    ///
    /// If nobody has built a playlist yet, the whole shelf becomes the
    /// playlist: there should always be a next game to warm, without asking
    /// the party to curate one first. Anyone can still `set_playlist` to
    /// override it.
    pub fn set_library(&mut self, library: Vec<GameMeta>) {
        if self.playlist.is_empty() {
            self.playlist.set_entries(
                library
                    .iter()
                    .map(|m| PlaylistEntry {
                        game: m.id.clone(),
                        title: m.title.clone(),
                    })
                    .collect(),
            );
        }
        self.library = library;
    }

    /// Put one more game on the shelf mid-night — a background install that
    /// just finished, and is playable from this moment rather than after a
    /// restart.
    ///
    /// Appends to the playlist rather than rebuilding it: the party may have
    /// curated an order already, and a download landing is no reason to throw
    /// that away. A game that's somehow already on the shelf updates in place,
    /// so a re-install can't produce a duplicate shelf entry.
    pub fn add_to_library(&mut self, meta: GameMeta) -> Vec<Effect> {
        let entry = PlaylistEntry {
            game: meta.id.clone(),
            title: meta.title.clone(),
        };
        match self.library.iter_mut().find(|m| m.id == meta.id) {
            Some(existing) => *existing = meta,
            None => {
                self.library.push(meta);
                if !self.playlist.entries().iter().any(|e| e.game == entry.game) {
                    // At the end, which is always after `current` — appending
                    // can't shift the pointer to what's playing.
                    self.playlist.insert(self.playlist.entries().len(), entry);
                }
            }
        }
        let mut fx = vec![Effect::StateChanged];
        // A shelf that was empty at boot has nothing warm; the arrival of the
        // first playable game is exactly when that should change.
        self.maybe_warm(&mut fx);
        fx
    }

    /// Start warming whatever currently fits, if nothing is warm yet.
    ///
    /// `set_library` populates the playlist but cannot emit effects, so at
    /// boot there is a shelf and no warm session — the lobby would sit on
    /// "Nothing queued" until some game happened to connect. The daemon calls
    /// this once it is ready to act on effects.
    pub fn ensure_warm(&mut self) -> Vec<Effect> {
        let mut fx = Vec::new();
        self.maybe_warm(&mut fx);
        fx
    }

    /// Feed one command in, get the effects out. The only entry point.
    pub fn handle(&mut self, command: Command) -> Vec<Effect> {
        let mut fx = Vec::new();
        match command {
            Command::GameConnected { game } => {
                let is_lobby = self.lobby_game.as_ref() == Some(&game);
                self.connected_games.insert(game);
                self.maybe_warm(&mut fx);
                self.try_transition(&mut fx);
                fx.push(Effect::StateChanged);
                if is_lobby {
                    // A lobby process that just started knows nothing about
                    // whose screen it is, and "it'll come up focused anyway"
                    // is only half true: it comes up *in the background*,
                    // launched as the daemon's child, which is not the same
                    // thing as having the couch's attention. Say it out loud
                    // instead of leaving it to guess — by forgetting what we
                    // last told the old process, so the sync below states the
                    // current truth whichever way it falls.
                    self.lobby_focused = !(self.active.is_none() || self.overlay_open);
                }
            }
            Command::GameDisconnected { game } => self.on_game_disconnected(game, &mut fx),
            Command::JoinParty {
                name,
                seat,
                color,
                avatar,
                library,
            } => self.on_join(name, seat, color, avatar, library, &mut fx),
            Command::LeaveParty { player_id } => self.on_leave(player_id, &mut fx),
            Command::RenamePlayer { player_id, name } => {
                self.on_rename_player(player_id, name, &mut fx)
            }
            Command::SetPlayerColor { player_id, color } => {
                self.on_set_player_color(player_id, color, &mut fx)
            }
            Command::SetPlayerAvatar { player_id, avatar } => {
                self.on_set_player_avatar(player_id, avatar, &mut fx)
            }
            Command::AssignSeat { seat, occupant } => self.on_assign_seat(seat, occupant, &mut fx),
            Command::BindController {
                player_id,
                controller,
            } => {
                if let Some(seat) = self
                    .seats
                    .iter_mut()
                    .find(|s| s.occupant.player_id() == Some(player_id))
                {
                    seat.controller = Some(controller);
                    self.rewarm_if_misfit(&mut fx);
                    fx.push(Effect::StateChanged);
                } else {
                    fx.push(Effect::Reject {
                        reason: "unknown seated player".into(),
                    });
                }
            }
            Command::SwapSeats { a, b } => self.on_swap_seats(a, b, &mut fx),
            Command::SetPlaylist { entries } => self.on_set_playlist(entries, &mut fx),
            Command::MovePlaylistEntry { expected, from, to } => {
                if self.playlist.snapshot() != expected
                    || from >= expected.entries.len()
                    || to >= expected.entries.len()
                {
                    fx.push(Effect::Reject {
                        reason: "playlist changed or invalid position; refresh and try again"
                            .into(),
                    });
                } else if from == to {
                    fx.push(Effect::StateChanged);
                } else {
                    let mut entries = expected.entries;
                    let entry = entries.remove(from);
                    entries.insert(to, entry);
                    // Track entries by their old index, including repeated games.
                    let remap = |index: usize| {
                        if index == from {
                            to
                        } else if from < to && index > from && index <= to {
                            index - 1
                        } else if to < from && index >= to && index < from {
                            index + 1
                        } else {
                            index
                        }
                    };
                    self.playlist.set_entries(entries);
                    if let Some(current) = expected.current {
                        self.playlist.set_current(remap(current));
                    }
                    if let Some(active) = &mut self.active {
                        active.playlist_index = remap(active.playlist_index);
                    }
                    if let Some(warm) = &mut self.warm {
                        warm.playlist_index = remap(warm.playlist_index);
                    }
                    self.next_up = None;
                    if self
                        .warm
                        .as_ref()
                        .is_some_and(|warm| Some(warm.playlist_index) != self.warm_target())
                    {
                        self.dispose_warm(&mut fx);
                    }
                    self.maybe_warm(&mut fx);
                    fx.push(Effect::StateChanged);
                }
            }
            Command::Next => {
                self.pending_transition = true;
                self.try_transition(&mut fx);
                fx.push(Effect::StateChanged);
            }
            Command::PlayNext { game } => self.on_play_next(game, &mut fx),
            Command::Pause => self.on_pause(&mut fx),
            Command::Resume => self.on_resume(&mut fx),
            Command::OverlayOpened => self.on_overlay_opened(&mut fx),
            Command::OverlayClosed => self.on_overlay_closed(&mut fx),
            Command::RequestStart { game } => self.on_request_start(game, &mut fx),
            Command::Vote { player_id, option } => self.on_vote(player_id, option, &mut fx),
            Command::SessionReady { session } => self.on_session_ready(session, &mut fx),
            Command::SessionProgress {
                session,
                percent,
                label,
            } => self.on_session_progress(session, percent, label, &mut fx),
            Command::SessionFinished { session } => self.on_session_finished(session, &mut fx),
            Command::InstallProgress { status } => self.on_install_progress(status, &mut fx),
            Command::NowPlaying { track } => self.on_now_playing(track, &mut fx),
            Command::MediaControl { action } => self.on_media_control(action, &mut fx),
            Command::DeclareSettings { game, settings } => {
                self.on_declare_settings(game, settings, &mut fx)
            }
            Command::SetSetting { game, key, value } => {
                self.on_set_setting(game, key, value, &mut fx)
            }
        }
        self.sync_lobby_focus(&mut fx);
        fx
    }

    /// Notifies the lobby game whenever whether it has the couch's
    /// attention actually changes — checked after every command rather than
    /// threaded through each of the several places `active` can change
    /// (a fresh transition, a crash rolling back to nothing warm, ...), so
    /// there's exactly one place this can drift from reality.
    fn sync_lobby_focus(&mut self, fx: &mut Vec<Effect>) {
        let Some(lobby_game) = self.lobby_game.clone() else {
            return;
        };
        // Nothing running, or the party called up the overlay: either way the
        // lobby is what the couch should be looking at. Without the overlay
        // half there is no way back from a running game short of ending it —
        // the active game keeps the screen, and "show me the party" has
        // nothing to show on.
        let should_be_focused = self.active.is_none() || self.overlay_open;
        if should_be_focused != self.lobby_focused {
            self.lobby_focused = should_be_focused;
            fx.push(Effect::LobbyFocus {
                game: lobby_game,
                active: should_be_focused,
            });
        }
    }

    // -- read model ---------------------------------------------------------

    pub fn snapshot(&self) -> PartySnapshot {
        PartySnapshot {
            players: self.players.clone(),
            seats: self.seats.clone(),
            playlist: self.playlist.snapshot(),
            active_session: self.active.as_ref().map(Session::info),
            warm_session: self.warm.as_ref().map(Session::info),
            // What we're heading for, so screens can say "starting" rather
            // than either lying about readiness or claiming an empty shelf.
            warming: self.warm.as_ref().map_or_else(
                || {
                    self.warm_target()
                        .and_then(|i| self.playlist.get(i))
                        // One process, one session: `maybe_warm` refuses to
                        // warm the game that is already playing, so naming it
                        // here parks the lobby's screen on "LOADING…" for a
                        // game the party is in the middle of — forever, since
                        // nothing is actually loading. On a short shelf the
                        // rotation target *is* the active game, so this is the
                        // common case, not an edge one.
                        .filter(|entry| self.active.as_ref().map(|a| &a.game) != Some(&entry.game))
                        .cloned()
                },
                |_| None,
            ),
            history: self.history.clone(),
            vote: self.vote.snapshot(),
            overlay_open: self.overlay_open,
            library: self.library.clone(),
            connected_games: {
                let mut games: Vec<_> = self.connected_games.iter().cloned().collect();
                games.sort_by(|a, b| a.0.cmp(&b.0));
                games
            },
            installs: self.installs.clone(),
            now_playing: self.now_playing.clone(),
            settings: {
                let mut settings = self.settings.clone();
                settings.sort_by(|a, b| a.game.0.cmp(&b.game.0));
                settings
            },
        }
    }

    /// The host's background music, if any is playing — chiefly so the daemon
    /// can answer `Effect::MediaControl` without cloning a whole snapshot to
    /// find out which app to talk to.
    pub fn now_playing(&self) -> Option<&NowPlaying> {
        self.now_playing.as_ref()
    }

    /// Players who currently hold a seat — the set whose consensus decides votes.
    fn voters(&self) -> Vec<PlayerId> {
        self.seats
            .iter()
            .filter_map(|s| s.occupant.player_id())
            .collect()
    }

    // -- command handlers ---------------------------------------------------

    fn on_join(
        &mut self,
        name: String,
        preferred: Option<u8>,
        color: Option<String>,
        avatar: Option<String>,
        library: Vec<GameId>,
        fx: &mut Vec<Effect>,
    ) {
        let player = Player {
            id: PlayerId::new(),
            name,
            color,
            avatar,
            library,
        };
        // Walk in, grab a controller, press A: your preferred seat if it's
        // free, otherwise the first free seat.
        let seat = preferred
            .and_then(|i| self.seats.get(usize::from(i)))
            .filter(|s| s.occupant.is_empty())
            .map(|s| s.index)
            .or_else(|| {
                self.seats
                    .iter()
                    .find(|s| s.occupant.is_empty())
                    .map(|s| s.index)
            });
        if let Some(index) = seat {
            self.seats[usize::from(index)].occupant = SeatOccupant::Local {
                player_id: player.id,
            };
        }
        self.players.push(player);
        fx.push(Effect::StateChanged);
        // A new seat may make the warm game a bad fit — or be the very first
        // thing that lets us warm anything at all.
        self.rewarm_if_misfit(fx);
    }

    fn on_set_player_avatar(&mut self, player_id: PlayerId, avatar: String, fx: &mut Vec<Effect>) {
        if let Some(player) = self.players.iter_mut().find(|p| p.id == player_id) {
            player.avatar = Some(avatar);
            fx.push(Effect::StateChanged);
        } else {
            fx.push(Effect::Reject {
                reason: format!("no such player: {:?}", player_id.0),
            });
        }
        self.rewarm_if_misfit(fx);
    }

    fn on_swap_seats(&mut self, a: u8, b: u8, fx: &mut Vec<Effect>) {
        let (a, b) = (usize::from(a), usize::from(b));
        if a >= self.seats.len() || b >= self.seats.len() {
            fx.push(Effect::Reject {
                reason: format!("no such seats to swap: {a}, {b}"),
            });
            return;
        }
        // People trade controllers; the seats (and their hardware) stay put.
        let occ_a = self.seats[a].occupant.clone();
        let occ_b = std::mem::replace(&mut self.seats[b].occupant, occ_a);
        self.seats[a].occupant = occ_b;
        fx.push(Effect::StateChanged);
        // Two people trading controllers means seat 0 is now a different
        // person — the warm session was prepared for the old arrangement.
        self.rewarm_if_misfit(fx);
    }

    fn on_overlay_opened(&mut self, fx: &mut Vec<Effect>) {
        if !self.overlay_open {
            self.overlay_open = true;
            // Opening the party pauses the game — but only a running one, and
            // we remember it was us so closing can undo it.
            if let Some(s) = &mut self.active {
                if s.phase == SessionPhase::Running {
                    s.advance(SessionPhase::Paused).expect("checked");
                    self.overlay_paused = true;
                    fx.push(Effect::ToGame {
                        game: s.game.clone(),
                        session: s.id,
                        command: GameCommand::Pause,
                    });
                }
            }
        }
        fx.push(Effect::StateChanged);
    }

    fn on_overlay_closed(&mut self, fx: &mut Vec<Effect>) {
        // Prepare is the roster boundary. Restart a paused round when seats
        // changed, instead of resuming a game that cannot see the new player.
        if let Some(active) = &self.active {
            if self.overlay_open
                && self.overlay_paused
                && (self.active_seats != self.seats_for(&active.game)
                    || self.active_players != self.players)
            {
                let index = active.playlist_index;
                let fits = self.game_has_capacity(&active.game);
                self.dispose_warm(fx);
                self.dispose_active(fx);
                self.next_up = fits.then_some(index);
                self.pending_transition = true;
                self.maybe_warm(fx);
                self.try_transition(fx);
                fx.push(Effect::StateChanged);
                return;
            }
        }
        if self.overlay_open {
            self.overlay_open = false;
            // Only undo our own pause; an explicit pause stays paused.
            if self.overlay_paused {
                self.overlay_paused = false;
                if let Some(s) = &mut self.active {
                    if s.phase == SessionPhase::Paused {
                        s.advance(SessionPhase::Running).expect("checked");
                        fx.push(Effect::ToGame {
                            game: s.game.clone(),
                            session: s.id,
                            command: GameCommand::Resume,
                        });
                    }
                }
            }
        }
        fx.push(Effect::StateChanged);
    }

    /// Somebody switched to `game`'s window. Whatever the party's plan was,
    /// this is what they want now.
    ///
    /// Deliberately narrow: it can start a game that is already warm and it
    /// can resume the one that's paused. It will not launch anything, warm
    /// anything, or reorder the playlist — a stray focus event (the window
    /// server hands focus around for all sorts of reasons) should never be
    /// able to change the night's plan, only to act on a session that is
    /// already sitting there ready to go.
    fn on_request_start(&mut self, game: GameId, fx: &mut Vec<Effect>) {
        // Already the game on screen: the only question is whether it's
        // paused, in which case reaching for it means "back in".
        if self.active.as_ref().is_some_and(|a| a.game == game) {
            // Same reasoning as closing the overlay — and the same guard:
            // only undo a pause the overlay caused. A deliberately paused
            // night stays paused.
            if self.overlay_open || self.overlay_paused {
                self.on_overlay_closed(fx);
            }
            return;
        }
        // The warm session, ready and waiting to be asked for. That's a
        // transition, exactly as if the party had pressed Next.
        if self
            .warm
            .as_ref()
            .is_some_and(|w| w.game == game && w.phase == SessionPhase::Ready)
        {
            // Reaching for a game while the overlay is up is still reaching
            // for the game: close it, or the transition would be immediately
            // paused again by an overlay nobody is looking at.
            if self.overlay_open {
                self.overlay_open = false;
                self.overlay_paused = false;
            }
            self.pending_transition = true;
            self.try_transition(fx);
            fx.push(Effect::StateChanged);
        }
    }

    fn on_leave(&mut self, player_id: PlayerId, fx: &mut Vec<Effect>) {
        self.players.retain(|p| p.id != player_id);
        for seat in &mut self.seats {
            if seat.occupant.player_id() == Some(player_id) {
                seat.occupant = SeatOccupant::Empty;
            }
        }
        // If the leaver was the lone holdout, the vote may now be unanimous.
        if let Some(decision) = self.vote.reevaluate(&self.voters()) {
            self.apply_vote_decision(decision, fx);
        }
        fx.push(Effect::StateChanged);
        // Someone leaving shrinks the party the same way joining grows it: a
        // four-player game warmed for four is the wrong thing to hand two.
        self.rewarm_if_misfit(fx);
    }

    fn on_rename_player(&mut self, player_id: PlayerId, name: String, fx: &mut Vec<Effect>) {
        match self.players.iter_mut().find(|p| p.id == player_id) {
            Some(p) => {
                p.name = name;
                fx.push(Effect::StateChanged);
            }
            None => fx.push(Effect::Reject {
                reason: "unknown player".into(),
            }),
        }
        self.rewarm_if_misfit(fx);
    }

    fn on_set_player_color(&mut self, player_id: PlayerId, color: String, fx: &mut Vec<Effect>) {
        match self.players.iter_mut().find(|p| p.id == player_id) {
            Some(p) => {
                p.color = Some(color);
                fx.push(Effect::StateChanged);
            }
            None => fx.push(Effect::Reject {
                reason: "unknown player".into(),
            }),
        }
        self.rewarm_if_misfit(fx);
    }

    fn on_assign_seat(&mut self, seat: u8, occupant: SeatOccupant, fx: &mut Vec<Effect>) {
        if usize::from(seat) >= self.seats.len() {
            fx.push(Effect::Reject {
                reason: format!("no seat {seat}"),
            });
            return;
        }
        if let Some(pid) = occupant.player_id() {
            if !self.players.iter().any(|p| p.id == pid) {
                fx.push(Effect::Reject {
                    reason: "unknown player".into(),
                });
                return;
            }
            // A player occupies at most one seat.
            for s in &mut self.seats {
                if s.occupant.player_id() == Some(pid) {
                    s.occupant = SeatOccupant::Empty;
                }
            }
        }
        self.seats[usize::from(seat)].occupant = occupant;
        fx.push(Effect::StateChanged);
        // Seating a bot, or moving someone, changes who the warm session was
        // prepared for just as much as a join does.
        self.rewarm_if_misfit(fx);
    }

    fn on_set_playlist(&mut self, entries: Vec<PlaylistEntry>, fx: &mut Vec<Effect>) {
        // A new playlist obsoletes whatever was warming for the old one. The
        // active session keeps playing; the new list takes over from the next
        // transition.
        self.dispose_warm(fx);
        self.next_up = None;
        self.playlist.set_entries(entries);
        // Re-anchor the "now playing" pointer in the new list, so the next
        // entry is computed relative to what's actually on screen.
        if let Some(a) = &mut self.active {
            if let Some(i) = self.playlist.position_of(&a.game) {
                a.playlist_index = i;
                self.playlist.set_current(i);
            }
        }
        self.maybe_warm(fx);
        fx.push(Effect::StateChanged);
    }

    /// Make `game` the next one up. If it's already in the playlist, aim the
    /// warm slot at it; otherwise insert it right after the current entry.
    fn on_play_next(&mut self, game: GameId, fx: &mut Vec<Effect>) {
        if !self.game_has_capacity(&game) {
            fx.push(Effect::Reject {
                reason: "this game cannot fit everyone in the party".into(),
            });
            return;
        }
        let index = match self.playlist.position_of(&game) {
            Some(i) => i,
            None => {
                let insert_at = self
                    .playlist
                    .current()
                    .map(|c| c + 1)
                    .unwrap_or_else(|| self.playlist.entries().len());
                // Entries at or after the insertion point shift by one, which
                // would leave a warm session pointing at the wrong entry.
                if self
                    .warm
                    .as_ref()
                    .is_some_and(|w| w.playlist_index >= insert_at)
                {
                    self.dispose_warm(fx);
                }
                let title = self
                    .library
                    .iter()
                    .find(|m| m.id == game)
                    .map(|m| m.title.clone())
                    .unwrap_or_else(|| game.0.clone());
                self.playlist
                    .insert(insert_at, PlaylistEntry { game, title });
                insert_at
            }
        };
        self.set_next_up(index, fx);
        // With nothing playing yet this doubles as "start the night here".
        if self.active.is_none() {
            self.pending_transition = true;
            self.try_transition(fx);
        }
        fx.push(Effect::StateChanged);
    }

    fn on_pause(&mut self, fx: &mut Vec<Effect>) {
        match &mut self.active {
            Some(s) if s.phase == SessionPhase::Running => {
                s.advance(SessionPhase::Paused).expect("checked");
                fx.push(Effect::ToGame {
                    game: s.game.clone(),
                    session: s.id,
                    command: GameCommand::Pause,
                });
                fx.push(Effect::StateChanged);
            }
            _ => fx.push(Effect::Reject {
                reason: "nothing running to pause".into(),
            }),
        }
    }

    fn on_resume(&mut self, fx: &mut Vec<Effect>) {
        match &mut self.active {
            Some(s) if s.phase == SessionPhase::Paused => {
                s.advance(SessionPhase::Running).expect("checked");
                // An explicit resume also settles an overlay pause.
                self.overlay_paused = false;
                fx.push(Effect::ToGame {
                    game: s.game.clone(),
                    session: s.id,
                    command: GameCommand::Resume,
                });
                fx.push(Effect::StateChanged);
            }
            _ => fx.push(Effect::Reject {
                reason: "nothing paused to resume".into(),
            }),
        }
    }

    fn on_vote(&mut self, player_id: PlayerId, option: VoteOption, fx: &mut Vec<Effect>) {
        let voters = self.voters();
        if let Some(decision) = self.vote.place(player_id, option, &voters) {
            self.apply_vote_decision(decision, fx);
        }
        fx.push(Effect::StateChanged);
    }

    fn apply_vote_decision(&mut self, decision: VoteOption, fx: &mut Vec<Effect>) {
        match decision {
            VoteOption::Replay => {
                // A replay is a brand-new session of the game we just played.
                if let Some(index) = self.active.as_ref().map(|a| a.playlist_index) {
                    self.set_next_up(index, fx);
                }
                self.pending_transition = true;
                self.try_transition(fx);
            }
            VoteOption::NextGame | VoteOption::Skip => {
                self.pending_transition = true;
                self.try_transition(fx);
            }
            VoteOption::Quit => {
                self.dispose_warm(fx);
                self.dispose_active(fx);
                self.pending_transition = false;
                fx.push(Effect::PartyOver);
            }
        }
    }

    /// Record how far along a warming game says it is, so the lobby can show
    /// the party something truthful while they wait. Only the warm session
    /// reports — once it's active there is nothing left to load, and a stale
    /// number on screen is worse than none.
    fn on_session_progress(
        &mut self,
        session: SessionId,
        percent: u8,
        label: Option<String>,
        fx: &mut Vec<Effect>,
    ) {
        let Some(warm) = self.warm.as_mut().filter(|w| w.id == session) else {
            // Not a rejection worth surfacing: progress for a session that
            // just started or was disposed is a normal race, not an error.
            return;
        };
        let percent = percent.min(100);
        if warm.progress == Some(percent) && warm.progress_label == label {
            return; // nothing changed; don't wake every screen up for it
        }
        warm.progress = Some(percent);
        warm.progress_label = label;
        fx.push(Effect::StateChanged);
    }

    /// Record what the background installer is doing with one game, so the
    /// lobby can show the party a game arriving before it is playable.
    ///
    /// Ordering is by state, not arrival: whatever is actually moving leads,
    /// then the queue, then the finished and failed. A screen that shows only
    /// one line then shows the right one without knowing any of this.
    fn on_install_progress(&mut self, status: InstallStatus, fx: &mut Vec<Effect>) {
        let percent = status.percent.map(|p| p.min(100));
        let status = InstallStatus { percent, ..status };

        match self.installs.iter_mut().find(|i| i.game == status.game) {
            // Same report twice is the common case while a download ticks
            // along inside one percent — dropping it keeps the broadcast
            // rate tied to visible change rather than to chunk size.
            Some(existing) if *existing == status => return,
            Some(existing) => *existing = status,
            None => self.installs.push(status),
        }

        self.installs.sort_by_key(|i| match i.state {
            InstallState::Downloading | InstallState::Verifying | InstallState::Extracting => 0,
            InstallState::Queued => 1,
            InstallState::Installed => 2,
            InstallState::Failed => 3,
        });
        fx.push(Effect::StateChanged);
    }

    /// Record whatever the host has on in the background.
    ///
    /// Only a real change broadcasts. The watcher polls on a timer and the
    /// answer is the same one most of the time, so re-broadcasting every poll
    /// would push a full party snapshot to every screen a few times a second
    /// for a track nobody touched.
    fn on_now_playing(&mut self, track: Option<NowPlaying>, fx: &mut Vec<Effect>) {
        if self.now_playing == track {
            return;
        }
        self.now_playing = track;
        fx.push(Effect::StateChanged);
    }

    /// Pass a pad press on to the host's music player.
    ///
    /// Nothing playing means there's nothing to talk to: no effect, no
    /// complaint. Screens only draw these controls when something *is*
    /// playing, so arriving here empty is a race with the track ending, not
    /// somebody doing something wrong.
    ///
    /// Play/pause flips the local read model on the way out. The watcher will
    /// confirm it within a poll, but a lobby pad that visibly does nothing for
    /// half a second is a pad people stand on twice — and two play/pauses are
    /// no play/pause at all. Skips get no such treatment: what the next track
    /// is called is not ours to guess, and the poll knows within the second.
    fn on_media_control(&mut self, action: MediaAction, fx: &mut Vec<Effect>) {
        let Some(track) = &mut self.now_playing else {
            return;
        };
        if action == MediaAction::PlayPause {
            track.playing = !track.playing;
            fx.push(Effect::StateChanged);
        }
        fx.push(Effect::MediaControl { action });
    }

    fn on_session_ready(&mut self, session: SessionId, fx: &mut Vec<Effect>) {
        // Loading may finish after a seat change has replaced the session.
        // Dispose and Ready cross in flight; this is not a game error.
        if self.retired_sessions.contains(&session) {
            return;
        }
        match &mut self.warm {
            Some(w) if w.id == session && w.phase == SessionPhase::Preparing => {
                w.advance(SessionPhase::Ready).expect("checked");
                // First game of the night starts the moment it's ready —
                // but only without a persistent lobby. With one, `active`
                // stays `None` for as long as the lobby's holding the
                // couch's attention (it's never itself a tracked session),
                // so this would otherwise auto-launch the very first warm
                // game the instant it connects, out from under whoever's
                // still in the lobby deciding what to play.
                if self.active.is_none() && self.lobby_game.is_none() {
                    self.pending_transition = true;
                }
                self.try_transition(fx);
                fx.push(Effect::StateChanged);
            }
            _ => fx.push(Effect::Reject {
                reason: "ready for unknown or non-preparing session".into(),
            }),
        }
    }

    fn on_session_finished(&mut self, session: SessionId, fx: &mut Vec<Effect>) {
        match &mut self.active {
            Some(a)
                if a.id == session
                    && matches!(a.phase, SessionPhase::Running | SessionPhase::Paused) =>
            {
                a.advance(SessionPhase::Finished).expect("checked");
                // A finished session has nothing left to resume.
                self.overlay_paused = false;
                if self.voters().is_empty() {
                    // Nobody seated to vote (demo mode / bots): just roll on.
                    self.pending_transition = true;
                    self.try_transition(fx);
                } else {
                    self.vote.open();
                    self.overlay_open = true;
                    // Finished games still own a window: pause tells the SDK
                    // to hide it while the lobby takes over for the next pick.
                    if let Some(active) = &self.active {
                        fx.push(Effect::ToGame {
                            game: active.game.clone(),
                            session: active.id,
                            command: GameCommand::Pause,
                        });
                    }
                }
                fx.push(Effect::StateChanged);
            }
            _ => fx.push(Effect::Reject {
                reason: "finished for unknown or non-running session".into(),
            }),
        }
    }

    fn on_declare_settings(&mut self, game: GameId, specs: Vec<SettingSpec>, fx: &mut Vec<Effect>) {
        // Reject malformed declarations outright — a bad spec caught here is
        // a bug report the game dev sees on day one, not a party stuck on an
        // un-settable knob.
        let mut seen = HashSet::new();
        for spec in &specs {
            if !seen.insert(spec.key.as_str()) {
                fx.push(Effect::Reject {
                    reason: format!("duplicate setting key '{}'", spec.key),
                });
                return;
            }
            if let Err(why) = spec.kind.validate(&spec.kind.default_value()) {
                fx.push(Effect::Reject {
                    reason: format!("setting '{}' has an illegal default: {why}", spec.key),
                });
                return;
            }
        }
        // Carry over values the party already chose, where still valid under
        // the new specs, and tell the (possibly freshly reconnected) game
        // about every value that differs from its default.
        let old = self
            .settings
            .iter()
            .position(|s| s.game == game)
            .map(|i| self.settings.remove(i));
        let mut values = std::collections::BTreeMap::new();
        for spec in &specs {
            let carried = old
                .as_ref()
                .and_then(|o| o.values.get(&spec.key))
                .filter(|v| spec.kind.validate(v).is_ok())
                .cloned();
            let value = carried.unwrap_or_else(|| spec.kind.default_value());
            if value != spec.kind.default_value() {
                fx.push(Effect::SettingChanged {
                    game: game.clone(),
                    key: spec.key.clone(),
                    value: value.clone(),
                });
            }
            values.insert(spec.key.clone(), value);
        }
        self.settings.push(GameSettings {
            game,
            specs,
            values,
        });
        fx.push(Effect::StateChanged);
    }

    fn on_set_setting(
        &mut self,
        game: Option<GameId>,
        key: String,
        value: SettingValue,
        fx: &mut Vec<Effect>,
    ) {
        let Some(game) = game.or_else(|| self.active.as_ref().map(|a| a.game.clone())) else {
            fx.push(Effect::Reject {
                reason: "no game given and nothing is playing".into(),
            });
            return;
        };
        let Some(entry) = self.settings.iter_mut().find(|s| s.game == game) else {
            fx.push(Effect::Reject {
                reason: format!("'{game}' has not declared any settings"),
            });
            return;
        };
        let Some(spec) = entry.specs.iter().find(|s| s.key == key) else {
            // Spell out the alternatives: this is the message an LLM (or a
            // squinting human) uses to correct itself.
            let known: Vec<&str> = entry.specs.iter().map(|s| s.key.as_str()).collect();
            fx.push(Effect::Reject {
                reason: format!(
                    "'{game}' has no setting '{key}'; available: {}",
                    known.join(", ")
                ),
            });
            return;
        };
        if let Err(why) = spec.kind.validate(&value) {
            fx.push(Effect::Reject {
                reason: format!("'{key}': {why}"),
            });
            return;
        }
        let changed = entry.values.insert(key.clone(), value.clone()) != Some(value.clone());
        if changed {
            fx.push(Effect::SettingChanged { game, key, value });
        }
        fx.push(Effect::StateChanged);
    }

    fn on_game_disconnected(&mut self, game: GameId, fx: &mut Vec<Effect>) {
        self.connected_games.remove(&game);
        // Sessions hosted by that process are gone; no Dispose can be delivered.
        if self.warm.as_ref().is_some_and(|w| w.game == game) {
            self.warm = None;
        }
        if self.active.as_ref().is_some_and(|a| a.game == game) {
            let a = self.active.take().expect("checked");
            self.history.push(a.game);
            self.vote.close();
            self.overlay_paused = false;
            // The active game crashed or quit — keep the night going.
            self.pending_transition = true;
            self.try_transition(fx);
        }
        // The lobby is meant to stay resident all night, so it disconnecting
        // means a fresh process is about to take its place (crash, quit, or
        // dev restart) — clear the party rather than let it inherit seats
        // occupied by players the new process never saw join, which
        // otherwise silently fills up and locks new joins out forever.
        if self.lobby_game.as_ref() == Some(&game) {
            self.players.clear();
            for seat in &mut self.seats {
                seat.occupant = SeatOccupant::Empty;
            }
        }
        fx.push(Effect::StateChanged);
    }

    // -- warm sessions & transitions ----------------------------------------

    /// How many seats are actually taken. This, not the number of seats the
    /// couch has, is what a game has to fit.
    pub fn seated_count(&self) -> u8 {
        self.seats
            .iter()
            .filter(|s| !s.occupant.is_empty())
            .count()
            .min(u8::MAX as usize) as u8
    }

    /// Whether `game`'s declared player range covers the current party.
    /// Games the shelf knows nothing about fit anything — see
    /// `GameMeta::fits_players`.
    fn game_has_capacity(&self, game: &GameId) -> bool {
        self.library
            .iter()
            .find(|m| &m.id == game)
            .and_then(|m| m.max_players)
            .is_none_or(|max| self.seated_count() <= max)
    }

    fn game_fits_party(&self, game: &GameId) -> bool {
        let players = self.seated_count();
        self.library
            .iter()
            .find(|m| &m.id == game)
            .is_none_or(|m| m.fits_players(players))
    }

    /// Whether playlist entry `index` is actually something that can be
    /// warmed/played — i.e. not the persistent lobby game itself. A lobby
    /// process is meant to stay resident all night (see `set_lobby_game`),
    /// not get cycled through like an ordinary match; if it ends up in the
    /// shelf/playlist anyway (its own launch spec has to live somewhere),
    /// rotation just steps past it.
    fn is_playable(&self, index: usize) -> bool {
        self.playlist
            .get(index)
            .is_some_and(|entry| self.lobby_game.as_ref() != Some(&entry.game))
    }

    /// Which playlist entry should be (or is being) warmed — skipping the
    /// lobby game if rotation would otherwise land on it.
    fn warm_target(&self) -> Option<usize> {
        if let Some(index) = self.next_up {
            if self.is_playable(index)
                && self
                    .playlist
                    .get(index)
                    .is_some_and(|e| self.game_has_capacity(&e.game))
            {
                return Some(index);
            }
            // An explicit pick somehow landed on the lobby game — fall
            // through to normal rotation instead of warming it.
        }
        let start = self.playlist.next_index()?;
        let len = self.playlist.entries().len();
        let rotation: Vec<usize> = (0..len)
            .map(|offset| (start + offset) % len)
            .filter(|&index| {
                self.is_playable(index)
                    && self
                        .playlist
                        .get(index)
                        .is_some_and(|e| self.game_has_capacity(&e.game))
            })
            .collect();

        // Respect the party's playlist order among playable games. A preferred
        // player count is a recommendation, not permission to undo a reorder.
        let fitting = rotation.iter().copied().find(|&index| {
            self.playlist
                .get(index)
                .is_some_and(|e| self.game_fits_party(&e.game))
        });
        // Below the minimum, bots can fill missing seats. Above the maximum,
        // entries were excluded: never leave a joined player out.
        fitting.or_else(|| rotation.first().copied())
    }

    /// Called whenever the seating changes: re-prepare or replace the warm
    /// session if it no longer matches the party.
    ///
    /// Two ways it can stop matching. Its *seats* can go stale — a session
    /// prepared for one player must never be started for two, and `prepare`
    /// is the only time a game is told who is playing, so the fix is a fresh
    /// one. Or the *game* itself can stop fitting, and something on the shelf
    /// suits the party better. The whole promise is that the next game is
    /// already warm and already right; both of these break it quietly, at
    /// the transition, when there is no time left to fix them.
    fn rewarm_if_misfit(&mut self, fx: &mut Vec<Effect>) {
        let Some(warm) = self.warm.as_ref() else {
            // Nothing warm yet — this is also the moment to start, since a
            // join may be the first thing that ever happens.
            self.maybe_warm(fx);
            return;
        };
        if !self.game_has_capacity(&warm.game) {
            self.dispose_warm(fx);
            self.next_up = None;
            self.maybe_warm(fx);
            return;
        }
        if self.warm_seats != self.seats_for(&warm.game) || self.warm_players != self.players {
            // Same game, new seating: warm it again rather than hunt for a
            // better title. `maybe_warm` re-reads the seats.
            self.dispose_warm(fx);
            self.maybe_warm(fx);
            return;
        }
        if self.game_fits_party(&warm.game) {
            return;
        }
        let game = warm.game.clone();
        // Only worth swapping if something better is actually available.
        let better = self.warm_target().and_then(|index| {
            self.playlist
                .get(index)
                .map(|e| e.game.clone())
                .filter(|g| g != &game && self.game_fits_party(g))
        });
        if better.is_none() {
            return;
        }
        // No logging here: this crate is the pure state machine and has no
        // tracing dependency. The daemon logs when it acts on the effects.
        self.dispose_warm(fx);
        self.next_up = None;
        self.maybe_warm(fx);
    }

    /// Point the warm slot at `index`, replacing a mismatched warm session.
    fn set_next_up(&mut self, index: usize, fx: &mut Vec<Effect>) {
        if self
            .warm
            .as_ref()
            .is_some_and(|w| w.playlist_index != index)
        {
            self.dispose_warm(fx);
        }
        self.next_up = Some(index);
        self.maybe_warm(fx);
    }

    /// Start preparing the next game if we can: there is a target entry, its
    /// game process is connected, and that process isn't busy running the
    /// active session.
    fn maybe_warm(&mut self, fx: &mut Vec<Effect>) {
        if self.warm.is_some() {
            return;
        }
        let Some(index) = self.warm_target() else {
            return;
        };
        let Some(entry) = self.playlist.get(index) else {
            return;
        };
        let game = entry.game.clone();
        if !self.connected_games.contains(&game) {
            // No process yet — ask the daemon to launch one if the library
            // knows how. Warming continues when GameConnected arrives.
            if self
                .library
                .iter()
                .any(|m| m.id == game && m.launch.is_some())
            {
                fx.push(Effect::Launch { game });
            }
            return;
        }
        if self.active.as_ref().is_some_and(|a| a.game == game) {
            // One process, one session: wait until the active session is
            // disposed (try_transition handles that).
            return;
        }
        let mut session = Session::new(game.clone(), index);
        session
            .advance(SessionPhase::Preparing)
            .expect("new session");
        let seats = self.seats_for(&game);
        self.warm_seats = seats.clone();
        self.warm_players = self.players.clone();
        fx.push(Effect::ToGame {
            game,
            session: session.id,
            command: GameCommand::Prepare {
                seats,
                players: self.players.clone(),
            },
        });
        self.warm = Some(session);
    }

    /// The party's seats as `game` should see them: empty seats filled with
    /// bots up to whatever the game says it needs to run.
    ///
    /// One person warming up before the others arrive is the everyday case,
    /// not an error to refuse — and a game that needs two players has to get
    /// two from somewhere. Deciding that here rather than in each game is the
    /// point: the alternative is every title inventing its own silent
    /// fallback, none of which the party can see, and half of which sit at a
    /// "waiting for player 2" screen forever instead.
    ///
    /// Only ever fills; a seat somebody is sitting in is never touched.
    fn seats_for(&self, game: &GameId) -> Vec<Seat> {
        let mut seats = self.seats.clone();
        let Some(min) = self
            .library
            .iter()
            .find(|m| &m.id == game)
            .and_then(|m| m.min_players)
        else {
            return seats;
        };
        let mut taken = self.seated_count();
        for seat in seats.iter_mut() {
            if taken >= min {
                break;
            }
            if seat.occupant.is_empty() {
                seat.occupant = SeatOccupant::Ai;
                taken += 1;
            }
        }
        seats
    }

    /// Run the requested transition if the warm session is ready:
    /// dispose the active game, promote the warm one, warm the next.
    fn try_transition(&mut self, fx: &mut Vec<Effect>) {
        if !self.pending_transition {
            return;
        }
        match &self.warm {
            Some(w) if w.phase == SessionPhase::Ready => {
                self.dispose_active(fx);
                let mut next = self.warm.take().expect("checked");
                self.active_seats = std::mem::take(&mut self.warm_seats);
                self.active_players = std::mem::take(&mut self.warm_players);
                next.advance(SessionPhase::Running)
                    .expect("ready -> running");
                fx.push(Effect::ToGame {
                    game: next.game.clone(),
                    session: next.id,
                    command: GameCommand::Start,
                });
                self.playlist.set_current(next.playlist_index);
                self.active = Some(next);
                self.next_up = None;
                self.pending_transition = false;
                self.vote.close();
                // The transition drops everyone straight into the new game:
                // the overlay closes itself.
                self.overlay_open = false;
                self.overlay_paused = false;
                self.maybe_warm(fx);
            }
            Some(_) => {
                // Still preparing; the transition fires on SessionReady.
            }
            None => {
                // Perhaps warming is blocked because the next entry runs on
                // the process occupied by the active session. Free it: the
                // transition was requested, the active game is done for.
                if let Some(index) = self.warm_target() {
                    let same_process = match (self.playlist.get(index), &self.active) {
                        (Some(entry), Some(active)) => entry.game == active.game,
                        _ => false,
                    };
                    if same_process {
                        self.dispose_active(fx);
                    }
                }
                self.maybe_warm(fx);
            }
        }
    }

    fn remember_disposed(&mut self, session: SessionId) {
        const RECENT_DISPOSALS: usize = 64;
        if self.retired_sessions.len() == RECENT_DISPOSALS {
            self.retired_sessions.pop_front();
        }
        self.retired_sessions.push_back(session);
    }

    fn dispose_active(&mut self, fx: &mut Vec<Effect>) {
        if let Some(mut a) = self.active.take() {
            // Whatever pause the overlay held on this session dies with it.
            self.overlay_paused = false;
            self.history.push(a.game.clone());
            a.advance(SessionPhase::Disposed).expect("live session");
            self.remember_disposed(a.id);
            fx.push(Effect::ToGame {
                game: a.game,
                session: a.id,
                command: GameCommand::Dispose,
            });
        }
    }

    fn dispose_warm(&mut self, fx: &mut Vec<Effect>) {
        self.warm_seats.clear();
        if let Some(mut w) = self.warm.take() {
            w.advance(SessionPhase::Disposed).expect("live session");
            self.remember_disposed(w.id);
            fx.push(Effect::ToGame {
                game: w.game,
                session: w.id,
                command: GameCommand::Dispose,
            });
        }
    }
}
