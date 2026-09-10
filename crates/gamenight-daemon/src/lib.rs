//! The GameNight daemon.
//!
//! Owns one [`GameNight`] state machine and speaks the wire protocol to two
//! kinds of WebSocket peers: game processes (SDKs) and overlays. All game
//! logic lives in `gamenight-core`; this crate only does IO — decode incoming
//! messages into [`Command`]s, execute the returned [`Effect`]s.

#[cfg(target_os = "macos")]
mod macos;
mod nowplaying;

use std::collections::HashMap;
use std::sync::Arc;

use futures_util::{SinkExt, StreamExt};
use tokio::io::AsyncBufReadExt;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, Mutex};
use tokio_tungstenite::tungstenite::Message;
use tracing::{debug, info, warn};

use gamenight_core::{Command, Effect, GameCommand, GameNight};
use gamenight_protocol::{
    ClientMessage, GameId, GameMeta, LaunchSpec, Role, ServerMessage, SessionId, ENV_ADDR,
    ENV_GAMENIGHT, ENV_GAME_ID, ENV_OVERLAY_URL, ENV_TOKEN, PROTOCOL_VERSION,
};

type Tx = mpsc::UnboundedSender<String>;

/// How long a spawned process gets to say hello before we give up on it.
///
/// Generous on purpose: a launch spec that's a pre-built binary connects in
/// well under a second, but one that's `cargo run --release` against a cold
/// (or even lukewarm) target dir can legitimately take minutes to compile
/// before the process even starts — a short timeout here doesn't fail
/// faster, it kills a genuinely-in-progress compile and restarts it from
/// scratch, which can never finish if every retry gets killed just as
/// slowly. Only an actually-dead child (`try_wait` returns `Some`) retries
/// immediately regardless of this timeout.
const LAUNCH_HELLO_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(600);

/// A game process the daemon spawned that hasn't said hello yet.
struct PendingLaunch {
    token: String,
    child: tokio::process::Child,
    spawned_at: std::time::Instant,
}

/// Everything shared between connections.
struct Shared {
    night: GameNight,
    /// One connection per game title. Second connection for the same title is
    /// rejected.
    games: HashMap<GameId, Tx>,
    overlays: HashMap<u64, Tx>,
    next_overlay_id: u64,
    /// The address games should connect to (passed via `GAMENIGHT_ADDR`).
    addr: String,
    /// Launch specs by game id, from the library.
    launch_specs: HashMap<GameId, gamenight_protocol::LaunchSpec>,
    /// Spawned, awaiting hello (keyed token verification).
    pending_launches: HashMap<GameId, PendingLaunch>,
    /// Spawned and connected; held so the party can kill them at quit time.
    running_children: HashMap<GameId, tokio::process::Child>,
    /// The title whose process just went away, for as long as we're
    /// reconciling that departure. A game must never be respawned by the
    /// very disconnect that ended it — see `launch`.
    quitting: Option<GameId>,
    /// Titles whose process has gone away and that we will not start again
    /// until somebody asks for them by name.
    ///
    /// Quitting a game is a thing a person does deliberately, and it has to
    /// mean something. Guarding only the departure itself wasn't enough: the
    /// next command warmed the title straight back up, so Cmd+Q was answered
    /// by the game reappearing — and on a short shelf, reappearing *and*
    /// auto-starting, because the party's earlier "play next" was still
    /// pending. Closing a window you didn't want open should not be a fight.
    ///
    /// Cleared the moment the party picks that game again (see `dispatch`),
    /// so this is "don't bring it back on your own", not "banned for the
    /// night".
    quit_games: std::collections::HashSet<GameId>,
    /// The background catalogue prewarm, if one is running — lets `launch`
    /// bump a game to the front of the download queue instead of silently
    /// no-oping when there's no launch spec for it yet.
    prewarm: Option<gamenight_installer::PrewarmHandle>,
    /// The party size the prewarm queue was last ordered for, so a seat change
    /// that doesn't change the count doesn't re-sort the queue.
    prewarm_players: Option<u8>,
    /// Packaged app lifetime: quitting the lobby also quits its host.
    exit_with_lobby: bool,
}

impl Shared {
    fn new(
        library: Vec<GameMeta>,
        addr: String,
        prewarm: Option<gamenight_installer::PrewarmHandle>,
    ) -> Self {
        let launch_specs = library
            .iter()
            .filter_map(|m| m.launch.clone().map(|l| (m.id.clone(), l)))
            .collect();
        let mut night = GameNight::default();
        night.set_library(library);
        Self {
            night,
            games: HashMap::new(),
            overlays: HashMap::new(),
            next_overlay_id: 0,
            addr,
            launch_specs,
            pending_launches: HashMap::new(),
            running_children: HashMap::new(),
            quitting: None,
            quit_games: std::collections::HashSet::new(),
            prewarm,
            // A fresh night genuinely has nobody seated, so recording that up
            // front keeps the first real join the first signal ever sent.
            prewarm_players: Some(0),
            exit_with_lobby: false,
        }
    }

    /// Keep the download queue pointed at games this many people can actually
    /// play. Called after every command, because "how many are playing" is
    /// answered by people picking up controllers throughout the evening, not
    /// once at boot — the fourth person arriving should change what's
    /// downloading next, not just what's playable now.
    fn sync_prewarm_players(&mut self) {
        let Some(prewarm) = &self.prewarm else { return };
        let players = self.night.snapshot().players.len().min(u8::MAX as usize) as u8;
        if self.prewarm_players == Some(players) {
            return;
        }
        self.prewarm_players = Some(players);
        prewarm.set_players(players);
    }

    /// Feed a command to the state machine and carry out its effects.
    /// `origin` receives any `Reject` effects.
    fn dispatch(&mut self, command: Command, origin: Option<&Tx>) {
        debug!(?command, "dispatch");
        // `Effect::Launch` only ever fires for a library entry that already
        // has a launch spec (`gamenight_core::maybe_warm`'s guard) — a
        // catalogue-only game that isn't installed yet never reaches
        // `launch()` that way. `PlayNext` is the party's explicit "make
        // this the next game" — the one place we know what's actually
        // wanted regardless of whether the state machine can act on it yet.
        // Asking to play something is what clears "the party closed this".
        //
        // Every command here is a person doing something deliberate, so all of
        // them count — including `Next`, which names no game at all. That one
        // is the lobby's own "start the next game" pad, and leaving it out
        // made the guard win an argument it had no business being in: stand on
        // the pad, and the daemon quietly refuses because the title was closed
        // earlier in the evening. A guard against the daemon acting on its own
        // must never override the party acting on purpose.
        match &command {
            Command::PlayNext { game } | Command::RequestStart { game } => {
                if self.quit_games.remove(game) {
                    info!(%game, "the party asked for it again — it may start");
                }
            }
            Command::Next if !self.quit_games.is_empty() => {
                info!("the party asked for the next game — nothing is off-limits");
                self.quit_games.clear();
            }
            _ => {}
        }
        if let Command::PlayNext { game } = &command {
            if !self.launch_specs.contains_key(game) {
                if let Some(prewarm) = &self.prewarm {
                    info!(%game, "playing an uninstalled catalogue game — bumping the prewarm queue");
                    prewarm.prioritize(game.0.clone());
                }
            }
        }
        let effects = self.night.handle(command);
        self.apply_effects(effects, origin);
        self.sync_prewarm_players();
    }

    /// Carry out the state machine's effects.
    ///
    /// Split out of `dispatch` because effects also arise outside any
    /// command — `GameNight::ensure_warm` at boot produces a `Launch`
    /// with nobody having asked for anything.
    fn apply_effects(&mut self, effects: Vec<Effect>, origin: Option<&Tx>) {
        let mut broadcast = false;
        for effect in effects {
            debug!(?effect, "effect");
            match effect {
                Effect::ToGame {
                    game,
                    session,
                    command,
                } => self.send_to_game(&game, session, command),
                Effect::StateChanged => broadcast = true,
                Effect::SettingChanged { game, key, value } => {
                    // Not session-scoped: settings outlive sessions. If the
                    // process is away, the value waits in the night's state
                    // and re-delivers when the game re-declares on reconnect.
                    if let Some(tx) = self.games.get(&game) {
                        send(tx, &ServerMessage::SettingChanged { game, key, value });
                    }
                }
                Effect::Launch { game } => self.launch(&game),
                Effect::LobbyFocus { game, active } => {
                    // Same reasoning as `SettingChanged`: not session-scoped,
                    // and if the lobby process is away there's nothing to
                    // tell — it'll come back up focused by default anyway.
                    if let Some(tx) = self.games.get(&game) {
                        send(tx, &ServerMessage::LobbyFocus { active });
                    }
                }
                Effect::MediaControl { action } => {
                    // Which app to talk to is the daemon's business, not the
                    // night's: the state machine knows a track is playing,
                    // this side knows it came from Spotify. A control with
                    // nothing playing is a race with the music stopping, and
                    // there's nobody left to send it to.
                    if let Some(source) = self.night.now_playing().map(|t| t.source.clone()) {
                        tokio::spawn(async move { nowplaying::control(&source, action).await });
                    }
                }
                Effect::PartyOver => {
                    info!("the party voted to quit — good night!");
                    self.kill_all_children();
                    broadcast = true;
                }
                Effect::Reject { reason } => {
                    warn!(%reason, "command rejected");
                    if let Some(tx) = origin {
                        send(tx, &ServerMessage::Error { message: reason });
                    }
                }
            }
        }
        if broadcast {
            let msg = ServerMessage::PartyState {
                party: self.night.snapshot(),
            };
            for tx in self.overlays.values() {
                send(tx, &msg);
            }
        }
    }

    fn send_to_game(&mut self, game: &GameId, session: SessionId, command: GameCommand) {
        let Some(tx) = self.games.get(game) else {
            // The process vanished between the state change and delivery; the
            // disconnect handler will reconcile the state machine.
            warn!(%game, "no connection for game, dropping command");
            return;
        };
        let msg = match command {
            GameCommand::PartyUpdated {
                seats,
                players,
                presence,
            } => ServerMessage::PartyUpdated {
                session,
                seats,
                players,
                presence,
            },
            GameCommand::Prepare { seats, players } => ServerMessage::Prepare {
                session,
                game: game.clone(),
                seats,
                players,
            },
            GameCommand::Start => ServerMessage::Start { session },
            GameCommand::Pause => ServerMessage::Pause { session },
            GameCommand::Resume => ServerMessage::Resume { session },
            GameCommand::Dispose => ServerMessage::Dispose { session },
        };
        send(tx, &msg);
    }

    /// Spawn the process for `game` per its launch spec, unless one is
    /// already connected or a spawn is in flight.
    fn launch(&mut self, game: &GameId) {
        if self.games.contains_key(game) {
            return;
        }
        // A spawn is in flight: keep waiting unless it died or stalled.
        if let Some(pending) = self.pending_launches.get_mut(game) {
            let died = matches!(pending.child.try_wait(), Ok(Some(_)));
            let stalled = pending.spawned_at.elapsed() > LAUNCH_HELLO_TIMEOUT;
            if !died && !stalled {
                return;
            }
            let mut stale = self.pending_launches.remove(game).expect("checked");
            warn!(%game, died, "launched process never said hello, retrying");
            let _ = stale.child.start_kill();
            tokio::spawn(async move {
                let _ = stale.child.wait().await;
            });
        }
        // Never respawn a game on the way out of its own disconnect. Losing
        // the active game makes the night pick what to play next, and with a
        // short shelf that pick is often the title that just left — so it
        // comes straight back, disconnects again, and the daemon spins,
        // putting windows on screen faster than a person can close them. You
        // can't even quit it, because quitting is what triggers the relaunch.
        //
        // Scoped to this one reconciliation rather than banning the title:
        // plenty of games exit cleanly when a match ends, and the playlist
        // must still be able to come back round to them later.
        if self.quitting.as_ref() == Some(game) {
            info!(%game, "not respawning a game that just quit");
            return;
        }
        // ...and it stays gone until asked for by name. See `quit_games`.
        if self.quit_games.contains(game) {
            info!(%game, "leaving a game the party closed alone until they ask for it");
            return;
        }
        let Some(spec) = self.launch_specs.get(game) else {
            // No launch spec — either never eligible for auto-install, or
            // still queued behind other downloads. Either way, bump it: if
            // it's mid-queue this makes it next; if it's already done or
            // ineligible, prioritize() is a no-op.
            if let Some(prewarm) = &self.prewarm {
                info!(%game, "no launch spec yet — bumping the background prewarm queue");
                prewarm.prioritize(game.0.clone());
            }
            return;
        };
        let token = uuid::Uuid::new_v4().to_string();
        let mut cmd = tokio::process::Command::new(&spec.command);
        cmd.args(&spec.args)
            .envs(&spec.env)
            .env(ENV_GAMENIGHT, "1")
            .env(ENV_ADDR, &self.addr)
            .env(ENV_GAME_ID, &game.0)
            .env(ENV_TOKEN, &token)
            .kill_on_drop(true);
        if let Some(cwd) = &spec.cwd {
            cmd.current_dir(cwd);
        }
        // Forward our own overlay URL, if set, so games can raise it (e.g. on
        // a controller Guide-button press) with zero per-game setup.
        if let Ok(overlay_url) = std::env::var(ENV_OVERLAY_URL) {
            cmd.env(ENV_OVERLAY_URL, overlay_url);
        }
        // Who has the screen right now — captured before the spawn, because
        // the spawn is what takes it away. See `macos::restore_frontmost`:
        // launching a process activates it, so warming a game behind a match
        // in progress pulls the screen off the match. Nothing the game can
        // set about its own window prevents that, so the launcher undoes it.
        #[cfg(target_os = "macos")]
        let displaced = macos::frontmost_pid();

        match cmd.spawn() {
            Ok(child) => {
                info!(%game, command = %spec.command, "launched game process");
                #[cfg(target_os = "macos")]
                if let Some(pid) = displaced {
                    tokio::spawn(async move {
                        // Twice, a beat apart: the activation we're undoing
                        // happens when the new process puts its window up,
                        // which is some way after `spawn` returns and varies
                        // with how fast the engine boots.
                        for delay_ms in [400, 1_500] {
                            tokio::time::sleep(std::time::Duration::from_millis(delay_ms)).await;
                            macos::restore_frontmost(pid);
                        }
                    });
                }
                self.pending_launches.insert(
                    game.clone(),
                    PendingLaunch {
                        token,
                        child,
                        spawned_at: std::time::Instant::now(),
                    },
                );
            }
            Err(e) => warn!(%game, command = %spec.command, error = %e, "failed to launch"),
        }
    }

    /// The night is over: take every child down.
    fn kill_all_children(&mut self) {
        let children = self
            .pending_launches
            .drain()
            .map(|(_, p)| p.child)
            .chain(self.running_children.drain().map(|(_, c)| c));
        for mut child in children {
            let _ = child.start_kill();
            tokio::spawn(async move {
                let _ = child.wait().await;
            });
        }
    }
}

fn send(tx: &Tx, msg: &ServerMessage) {
    // A closed channel means the peer is gone; its reader task cleans up.
    let _ = tx.send(msg.to_json());
}

/// Watches every connected controller for a Back/Select press and launches
/// `lobby_game` (per its library launch spec) the moment one comes in and
/// it isn't already connected — the way back when the lobby has crashed or
/// been quit. Starting the night doesn't need it: the daemon brings the lobby
/// up itself (see `run_with_prewarm`). Once the lobby app is up, its own
/// global input polling takes over entirely (see `gamenight-overlay`/the lobby's
/// own `gamenight.rs`); this only ever needs to handle the "nothing is
/// listening yet" case.
///
/// Runs on its own OS thread (`gilrs` is blocking, and this needs to react
/// the instant a controller button is pressed, not on some polling
/// interval) forwarding through a channel to a tokio task that can lock
/// `Shared` and reuse the exact same launch path `PlayNext`/warming already
/// use.
fn spawn_launcher_watch(shared: Arc<Mutex<Shared>>, lobby_game: GameId) {
    let (tx, mut rx) = mpsc::unbounded_channel::<()>();
    if let Err(e) = std::thread::Builder::new()
        .name("gamenight-launcher-watch".into())
        .spawn(move || {
            let mut gilrs = match gilrs::Gilrs::new() {
                Ok(g) => g,
                Err(e) => {
                    warn!("launcher-watch: could not start gilrs (gamepad backend): {e}");
                    return;
                }
            };
            loop {
                let Some(gilrs::Event { event, .. }) = gilrs.next_event_blocking(None) else {
                    continue;
                };
                if let gilrs::EventType::ButtonPressed(gilrs::Button::Select, _) = event {
                    if tx.send(()).is_err() {
                        break; // the daemon task is gone
                    }
                }
            }
        })
    {
        warn!("launcher-watch: could not spawn thread: {e}");
        return;
    }

    tokio::spawn(async move {
        while rx.recv().await.is_some() {
            let mut shared = shared.lock().await;
            if !shared.games.contains_key(&lobby_game) {
                info!(%lobby_game, "back pressed with nothing running — launching the lobby");
                // Pressing Back *is* asking for it, so a lobby that was closed
                // earlier is allowed back.
                shared.quit_games.remove(&lobby_game);
                shared.launch(&lobby_game);
            }
        }
    });
}

/// Watch whatever the host has playing in the background and keep the party
/// state in step with it, so every screen can show the room what's on.
///
/// Off by an env var because talking to another app is a thing macOS asks the
/// host to approve, and a host who doesn't want GameNight anywhere near their
/// music should be able to say so without giving up the daemon.
fn spawn_now_playing_watch(shared: Arc<Mutex<Shared>>) {
    if std::env::var_os("GAMENIGHT_NO_MUSIC").is_some() {
        info!("not watching the host's music (GAMENIGHT_NO_MUSIC)");
        return;
    }
    // The watcher is a plain loop with a synchronous callback, so it hands
    // each change to a task rather than locking the party state itself —
    // holding that lock across a poll would park every other connection on a
    // question about somebody's Spotify.
    let (tx, mut rx) = mpsc::unbounded_channel();
    tokio::spawn(nowplaying::watch(move |track| {
        let _ = tx.send(track);
    }));
    tokio::spawn(async move {
        while let Some(track) = rx.recv().await {
            shared
                .lock()
                .await
                .dispatch(Command::NowPlaying { track }, None);
        }
    });
}

/// Feed the background installer's progress into the party state, and put a
/// finished install on the shelf the moment it lands.
///
/// That second half is the point: without it a game downloaded mid-evening
/// stays invisible until the daemon restarts, so the party watches a bar
/// reach 100% and then has nothing to press. Resolving the shelf entry here
/// (rather than having the installer report it) reuses exactly the same
/// `already_installed` + `game_meta` path the startup scan uses, so a game
/// that arrives mid-night is indistinguishable from one that was there all
/// along.
fn spawn_install_progress_pump(
    shared: Arc<Mutex<Shared>>,
    mut rx: mpsc::UnboundedReceiver<gamenight_protocol::InstallStatus>,
) {
    let root = gamenight_installer::install_dir();
    let catalog_dir = gamenight_catalog::catalog_dir();
    tokio::spawn(async move {
        while let Some(status) = rx.recv().await {
            if status.state == gamenight_protocol::InstallState::Installed {
                if let Some(meta) = resolve_installed_meta(&catalog_dir, &root, &status.game).await
                {
                    info!(game = %status.game, "background install joined the shelf");
                    let mut s = shared.lock().await;
                    if let Some(launch) = &meta.launch {
                        s.launch_specs.insert(meta.id.clone(), launch.clone());
                    }
                    let fx = s.night.add_to_library(meta);
                    s.apply_effects(fx, None);
                }
            }
            let mut s = shared.lock().await;
            let fx = s.night.handle(Command::InstallProgress { status });
            s.apply_effects(fx, None);
        }
    });
}

/// The shelf entry for a game that just finished installing, or `None` if the
/// catalogue no longer describes it or the files aren't where they should be.
async fn resolve_installed_meta(
    catalog_dir: &std::path::Path,
    root: &std::path::Path,
    game: &GameId,
) -> Option<GameMeta> {
    let entries = gamenight_catalog::load_dir(catalog_dir).ok()?;
    let entry = entries.iter().find(|e| e.id == game.0)?;
    let installed = gamenight_installer::already_installed(entry, root).await?;
    Some(gamenight_installer::game_meta(entry, &installed))
}

/// The bundled lobby, if this daemon was shipped with one.
///
/// The lobby is the one game that must be there before anything else works —
/// it *is* the couch — so it can't come from the catalogue's download path
/// like other titles. It ships inside the application, and the daemon finds
/// it the same way it finds the demo game: beside its own executable.
///
/// `cwd` is set to the directory holding `assets/`, because that's how the
/// lobby locates them (it also accepts `LOBBY_ASSETS`, which we set explicitly so
/// the working directory isn't load-bearing).
pub fn bundled_lobby_meta() -> Option<GameMeta> {
    let exe = std::env::current_exe().ok()?;
    let bin_dir = exe.parent()?;

    // GameNight.app/Contents/MacOS/lobby, or a plain side-by-side layout.
    let candidates = [
        bin_dir.join("lobby"),
        bin_dir.join("lobby/lobby"),
        bin_dir.join("../Resources/lobby/lobby"),
    ];
    let command = candidates.into_iter().find(|p| p.is_file())?;
    let dir = command.parent()?.to_path_buf();

    // Assets live either next to the binary or in the bundle's Resources.
    let assets = [dir.join("assets"), dir.join("../Resources/assets")]
        .into_iter()
        .find(|p| p.is_dir())?;

    info!(command = %command.display(), "bundled lobby found");
    let mut env = std::collections::BTreeMap::new();
    env.insert("LOBBY_ASSETS".to_string(), assets.display().to_string());

    Some(GameMeta {
        id: GameId::new("lobby"),
        title: "GameNight Lobby".into(),
        tagline: Some("The couch you gather on.".into()),
        cover: None,
        color: Some("#6366f1".into()),
        emoji: Some("🛋️".into()),
        players: Some("1–4".into()),
        min_players: Some(1),
        max_players: Some(4),
        best_players: Some(4),
        launch: Some(LaunchSpec {
            command: command.display().to_string(),
            args: Vec::new(),
            cwd: Some(dir.display().to_string()),
            env,
        }),
    })
}

/// The built-in demo shelf, used when no library file is configured. Covers
/// are generated by overlays from `color` + `emoji`; a real deployment points
/// `GAMENIGHT_LIBRARY` at a JSON file with proper `cover` art URLs.
/// Where the bundled demo game's binary is, if it was built.
///
/// Resolved at runtime rather than hardcoded: cargo puts workspace binaries
/// next to each other, so looking beside the daemon's own executable covers
/// `cargo run`, `cargo install`, and a packaged layout alike. Falls back to
/// the debug target path for the case where the daemon is run some other way.
fn demo_game_launch() -> Option<LaunchSpec> {
    let mut candidates = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            candidates.push(dir.join("demo-game"));
        }
    }
    candidates.push(std::path::PathBuf::from("target/debug/demo-game"));
    candidates.push(std::path::PathBuf::from("target/release/demo-game"));

    let command = candidates.into_iter().find(|p| p.is_file())?;
    info!(command = %command.display(), "demo game is launchable — it can be warmed");
    Some(LaunchSpec {
        command: command.display().to_string(),
        args: Vec::new(),
        cwd: None,
        env: Default::default(),
    })
}

/// The development shelf, used when neither `GAMENIGHT_LIBRARY` nor a bundled
/// lobby is present. Exactly one entry, and it is one the daemon can actually
/// start.
///
/// It used to carry six more — TowerFall, Duck Game, Stick Fight and friends —
/// as illustrative cover art with no `launch`. They made the shelf look
/// populated while every one of them was unstartable, which is precisely the
/// lie this project exists to remove: a shelf is a promise that pressing Ⓐ
/// does something.
pub fn demo_library() -> Vec<GameMeta> {
    vec![GameMeta {
        id: GameId::new("demo-game"),
        title: "Demo Game".into(),
        tagline: Some("A tiny SDK game, warm and waiting.".into()),
        cover: None,
        color: Some("#3ddc97".into()),
        emoji: Some("🎲".into()),
        players: Some("1–4".into()),
        min_players: Some(1),
        max_players: Some(4),
        best_players: Some(2),
        launch: demo_game_launch(),
    }]
}

/// Load the shelf from a JSON file (an array of `GameMeta`).
pub fn load_library(path: &str) -> std::io::Result<Vec<GameMeta>> {
    let text = std::fs::read_to_string(path)?;
    let mut library: Vec<GameMeta> = serde_json::from_str(&text).map_err(|e| {
        std::io::Error::new(std::io::ErrorKind::InvalidData, format!("bad library file {path}: {e}"))
    })?;
    let root = std::path::Path::new(path).parent().unwrap_or(std::path::Path::new("."));
    for game in &mut library {
        if let Some(cover) = game.cover.clone().filter(|cover| !cover.contains("://") && !cover.starts_with("data:")) {
            let relative = std::path::Path::new(&cover);
            let safe = !relative.is_absolute() && relative.components().all(|part| matches!(part, std::path::Component::Normal(_) | std::path::Component::CurDir));
            game.cover = if safe {
                std::fs::File::open(root.join(relative)).ok().and_then(|file| {
                    use std::io::Read;
                    let mut bytes = Vec::new();
                    file.take((gamenight_protocol::artwork::MAX_PNG_BYTES + 1) as u64).read_to_end(&mut bytes).ok()?;
                    gamenight_protocol::artwork::png_data_uri(&bytes)
                })
            } else { None };
            if game.cover.is_none() { tracing::warn!(game = ?game.id, "cover unavailable; using title/color fallback"); }
        }
    }
    Ok(library)
}

/// Run the daemon on an already-bound listener until the process is stopped.
/// Binding is left to the caller so tests can use port 0.
pub async fn run(listener: TcpListener) -> std::io::Result<()> {
    run_with_library(listener, demo_library()).await
}

/// Like [`run`], with an explicit game shelf.
pub async fn run_with_library(
    listener: TcpListener,
    library: Vec<GameMeta>,
) -> std::io::Result<()> {
    run_with_lobby(listener, library, None).await
}

/// Like [`run_with_library`], additionally watching every connected
/// controller for a Back/Select press and launching `lobby_game` (if given)
/// the moment one comes in and it isn't already connected — see
/// `spawn_launcher_watch`. `None` (what `run`/`run_with_library` pass)
/// disables the watch entirely; there's no reason for it in tests, which
/// spawn many daemons per process and have no controllers to watch anyway.
pub async fn run_with_lobby(
    listener: TcpListener,
    library: Vec<GameMeta>,
    lobby_game: Option<GameId>,
) -> std::io::Result<()> {
    run_with_prewarm(listener, library, lobby_game, None).await
}

/// Like [`run_with_lobby`], additionally wired to a background catalogue
/// prewarm: when the party wants to warm a game with no launch spec yet,
/// `launch` bumps it to the front of `prewarm`'s download queue instead of
/// silently doing nothing. `None` (what every other `run*` variant passes)
/// just skips that bump — the game stays unlaunchable until its download
/// gets there on its own.
pub async fn run_with_prewarm(
    listener: TcpListener,
    library: Vec<GameMeta>,
    lobby_game: Option<GameId>,
    prewarm: Option<gamenight_installer::PrewarmHandle>,
) -> std::io::Result<()> {
    run_inner(listener, library, lobby_game, prewarm, None, false, false).await
}

/// [`run_with_prewarm`], plus the background installer's progress stream and
/// a watch on the host's own music — what the real daemon runs, so the lobby
/// can show games arriving and the record that's already on.
pub async fn run_with_prewarm_progress(
    listener: TcpListener,
    library: Vec<GameMeta>,
    lobby_game: Option<GameId>,
    prewarm: Option<gamenight_installer::PrewarmHandle>,
    install_progress: Option<mpsc::UnboundedReceiver<gamenight_protocol::InstallStatus>>,
) -> std::io::Result<()> {
    run_inner(
        listener,
        library,
        lobby_game,
        prewarm,
        install_progress,
        true,
        false,
    )
    .await
}

/// Run a packaged desktop app. Closing the lobby ends the host and its games.
/// Headless/resident callers should use [`run_with_lobby`] instead.
pub async fn run_desktop(
    listener: TcpListener,
    library: Vec<GameMeta>,
    lobby_game: GameId,
    prewarm: Option<gamenight_installer::PrewarmHandle>,
    install_progress: Option<mpsc::UnboundedReceiver<gamenight_protocol::InstallStatus>>,
) -> std::io::Result<()> {
    run_inner(
        listener,
        library,
        Some(lobby_game),
        prewarm,
        install_progress,
        true,
        true,
    )
    .await
}

/// The one real body behind the `run*` family.
///
/// `music` is what separates the shipped daemon from the ones tests spin up by
/// the dozen: watching the host's music means asking the machine's real music
/// players about themselves every couple of seconds, which is right for the
/// evening's daemon and wrong for a test that wanted a socket.
async fn run_inner(
    listener: TcpListener,
    library: Vec<GameMeta>,
    lobby_game: Option<GameId>,
    prewarm: Option<gamenight_installer::PrewarmHandle>,
    install_progress: Option<mpsc::UnboundedReceiver<gamenight_protocol::InstallStatus>>,
    music: bool,
    exit_with_lobby: bool,
) -> std::io::Result<()> {
    let addr = listener.local_addr()?;
    info!(%addr, "gamenight daemon listening");
    let shared = Arc::new(Mutex::new(Shared::new(library, addr.to_string(), prewarm)));
    shared.lock().await.exit_with_lobby = exit_with_lobby;
    let watched_lobby = lobby_game.clone().filter(|_| exit_with_lobby);
    if let Some(rx) = install_progress {
        spawn_install_progress_pump(shared.clone(), rx);
    }
    if music {
        spawn_now_playing_watch(shared.clone());
    }
    if let Some(lobby_game) = lobby_game {
        let mut s = shared.lock().await;
        s.night.set_lobby_game(Some(lobby_game.clone()));
        // Put the couch on screen. The lobby is the one thing the party must
        // never have to start for themselves — "the daemon is the launcher"
        // is the whole premise — and waiting for a Back press meant a night
        // that began with a warm game sliding into the background and then
        // nothing at all: no lobby, no shelf, nothing to press Back *with* if
        // no controller is paired yet. Before the warm below, so the lobby is
        // what comes up first and the warm game arrives behind it.
        s.launch(&lobby_game);
        drop(s);
        if !exit_with_lobby {
            spawn_launcher_watch(shared.clone(), lobby_game);
        }
    }
    {
        // Warm something immediately rather than waiting for a game to
        // connect. `set_library` fills the shelf but can't emit effects, so
        // without this the first thing anyone sees is "Nothing queued".
        let mut s = shared.lock().await;
        let fx = s.night.ensure_warm();
        if !fx.is_empty() {
            info!("pre-warming the first game for the shelf");
        }
        s.apply_effects(fx, None);
    }
    let mut presence_tick = tokio::time::interval(std::time::Duration::from_secs(1));
    let mut presence_at = std::time::Instant::now();
    let mut lifetime_tick = tokio::time::interval(std::time::Duration::from_millis(200));
    loop {
        let accepted = tokio::select! {
            accepted = listener.accept() => accepted,
            _ = presence_tick.tick() => {
                let now = std::time::Instant::now();
                let elapsed = now.duration_since(presence_at);
                presence_at = now;
                let mut s = shared.lock().await;
                let fx = s.night.handle(Command::PresenceTick { elapsed });
                s.apply_effects(fx, None);
                continue;
            },
            _ = lifetime_tick.tick(), if watched_lobby.is_some() => {
                let mut s = shared.lock().await;
                let lobby = watched_lobby.as_ref().expect("guarded");
                let child = if let Some(pending) = s.pending_launches.get_mut(lobby) {
                    Some(&mut pending.child)
                } else {
                    s.running_children.get_mut(lobby)
                };
                let alive = match child {
                    Some(child) => child.try_wait()?.is_none(),
                    None => false,
                };
                if !alive {
                    s.kill_all_children();
                    return Ok(());
                }
                continue;
            }
        };
        let (stream, peer) = accepted?;
        let shared = shared.clone();
        tokio::spawn(async move {
            if let Err(e) = handle_connection(stream, shared).await {
                debug!(%peer, error = %e, "connection ended");
            }
        });
    }
}

/// One peer's inbound half, whichever transport it arrived on.
///
/// Both carry exactly the same JSON messages; the only difference is the
/// framing the peer had to produce to get them here.
enum Inbound {
    Ws(futures_util::stream::SplitStream<tokio_tungstenite::WebSocketStream<TcpStream>>),
    Lines(tokio::io::Lines<tokio::io::BufReader<tokio::net::tcp::OwnedReadHalf>>),
}

impl Inbound {
    /// The next protocol message, or `None` when the peer hangs up.
    ///
    /// Transport-level noise (pings, blank keepalive lines) is swallowed
    /// here so the session loop only ever sees real messages.
    async fn next_message(&mut self) -> Result<Option<String>, BoxError> {
        loop {
            match self {
                Inbound::Ws(reader) => match reader.next().await {
                    Some(Ok(Message::Text(text))) => return Ok(Some(text)),
                    Some(Ok(Message::Ping(_) | Message::Pong(_))) => continue,
                    Some(Ok(Message::Close(_))) | None => return Ok(None),
                    Some(Ok(_)) => continue,
                    Some(Err(e)) => return Err(e.into()),
                },
                Inbound::Lines(lines) => match lines.next_line().await? {
                    Some(line) if line.trim().is_empty() => continue,
                    Some(line) => return Ok(Some(line)),
                    None => return Ok(None),
                },
            }
        }
    }
}

type BoxError = Box<dyn std::error::Error + Send + Sync>;

/// Sniff which transport a fresh connection is speaking and set it up.
///
/// A WebSocket client opens with an HTTP upgrade, so the first bytes are
/// `GET `. Anything else is taken to be the plain transport: one JSON object
/// per line, no framing, no handshake. See `docs/protocol.md#transport` —
/// the plain form exists so a game whose engine has no WebSocket library
/// (most C/C++ engines) can still integrate with a socket and `printf`.
async fn handle_connection(stream: TcpStream, shared: Arc<Mutex<Shared>>) -> Result<(), BoxError> {
    let mut probe = [0u8; 4];
    let mut seen = 0;
    while seen < probe.len() {
        stream.readable().await?;
        match stream.peek(&mut probe).await? {
            0 => return Err("closed before hello".into()),
            n => seen = n,
        }
    }

    let (reader, tx, writer) = if &probe == b"GET " {
        let (sink, reader) = tokio_tungstenite::accept_async(stream).await?.split();
        let (tx, rx) = mpsc::unbounded_channel::<String>();
        (Inbound::Ws(reader), tx, tokio::spawn(pump_ws(sink, rx)))
    } else {
        let (read, write) = stream.into_split();
        let (tx, rx) = mpsc::unbounded_channel::<String>();
        let lines = tokio::io::BufReader::new(read).lines();
        (
            Inbound::Lines(lines),
            tx,
            tokio::spawn(pump_lines(write, rx)),
        )
    };
    serve(reader, tx, writer, shared).await
}

/// Writer task for a WebSocket peer: one text frame per message.
async fn pump_ws(
    mut sink: futures_util::stream::SplitSink<
        tokio_tungstenite::WebSocketStream<TcpStream>,
        Message,
    >,
    mut rx: mpsc::UnboundedReceiver<String>,
) {
    while let Some(msg) = rx.recv().await {
        if sink.send(Message::Text(msg)).await.is_err() {
            break;
        }
    }
    let _ = sink.close().await;
}

/// Writer task for a plain peer: one JSON object per line.
async fn pump_lines(
    mut write: tokio::net::tcp::OwnedWriteHalf,
    mut rx: mpsc::UnboundedReceiver<String>,
) {
    use tokio::io::AsyncWriteExt;
    while let Some(msg) = rx.recv().await {
        // One write per message: a partial line would desync the peer's
        // parser, and these are small enough that batching buys nothing.
        if write.write_all(msg.as_bytes()).await.is_err() || write.write_all(b"\n").await.is_err() {
            break;
        }
    }
    let _ = write.shutdown().await;
}

/// The protocol itself, identical on both transports: hello, register, then
/// pump messages into the state machine until the peer goes away.
async fn serve(
    mut reader: Inbound,
    tx: Tx,
    writer: tokio::task::JoinHandle<()>,
    shared: Arc<Mutex<Shared>>,
) -> Result<(), BoxError> {
    // First message must be a hello.
    let hello = match reader.next_message().await? {
        Some(text) => serde_json::from_str::<ClientMessage>(&text)?,
        None => return Err("closed before hello".into()),
    };
    let ClientMessage::Hello { role, game, token } = hello else {
        return Err("first message must be hello".into());
    };

    let registration = match role {
        Role::Game => {
            let Some(game_id) = game else {
                send(
                    &tx,
                    &ServerMessage::Error {
                        message: "game hello requires a game id".into(),
                    },
                );
                return Err("game hello without game id".into());
            };
            let mut s = shared.lock().await;
            if s.games.contains_key(&game_id) {
                send(
                    &tx,
                    &ServerMessage::Error {
                        message: format!("a process for game '{game_id}' is already connected"),
                    },
                );
                return Err("duplicate game connection".into());
            }
            // If the daemon launched a process for this title, only the
            // holder of that launch token may claim the id.
            if let Some(pending) = s.pending_launches.get(&game_id) {
                if token.as_deref() != Some(pending.token.as_str()) {
                    send(
                        &tx,
                        &ServerMessage::Error {
                            message: format!(
                                "a launched process for '{game_id}' is expected; \
                                 bad or missing launch token"
                            ),
                        },
                    );
                    return Err("bad launch token".into());
                }
                let pending = s.pending_launches.remove(&game_id).expect("checked");
                s.running_children.insert(game_id.clone(), pending.child);
            }
            info!(game = %game_id, launched = s.running_children.contains_key(&game_id), "game connected");
            s.games.insert(game_id.clone(), tx.clone());
            send(
                &tx,
                &ServerMessage::Welcome {
                    protocol_version: PROTOCOL_VERSION,
                    party: s.night.snapshot(),
                },
            );
            s.dispatch(
                Command::GameConnected {
                    game: game_id.clone(),
                },
                Some(&tx),
            );
            Registration::Game(game_id)
        }
        Role::Overlay => {
            let mut s = shared.lock().await;
            let id = s.next_overlay_id;
            s.next_overlay_id += 1;
            info!(overlay = id, "overlay connected");
            s.overlays.insert(id, tx.clone());
            send(
                &tx,
                &ServerMessage::Welcome {
                    protocol_version: PROTOCOL_VERSION,
                    party: s.night.snapshot(),
                },
            );
            Registration::Overlay(id)
        }
    };

    // Main read loop.
    let result: Result<(), BoxError> = async {
        while let Some(text) = reader.next_message().await? {
            let parsed: ClientMessage = match serde_json::from_str(&text) {
                Ok(m) => m,
                Err(e) => {
                    send(
                        &tx,
                        &ServerMessage::Error {
                            message: format!("bad message: {e}"),
                        },
                    );
                    continue;
                }
            };
            let command = match message_to_command(parsed, &registration) {
                Ok(Some(c)) => c,
                Ok(None) => continue,
                Err(reason) => {
                    send(&tx, &ServerMessage::Error { message: reason });
                    continue;
                }
            };
            shared.lock().await.dispatch(command, Some(&tx));
        }
        Ok(())
    }
    .await;

    // Unregister and reconcile.
    {
        let mut s = shared.lock().await;
        match &registration {
            Registration::Game(game_id) => {
                info!(game = %game_id, "game disconnected");
                s.games.remove(game_id);
                // If we spawned this process, reap it (crash or clean exit —
                // GameDisconnected reconciles the night either way).
                if let Some(mut child) = s.running_children.remove(game_id) {
                    if s.exit_with_lobby {
                        let _ = child.start_kill();
                    }
                    tokio::spawn(async move {
                        let _ = child.wait().await;
                    });
                }
                // Reconciling a lost game decides what to play next, and that
                // decision must not be allowed to bring this one back — see
                // `launch`. The guard covers exactly this dispatch.
                s.quitting = Some(game_id.clone());
                // And keep it closed. Whether this was Cmd+Q, a crash or a
                // clean exit, bringing it back unasked is the daemon arguing
                // with the person holding the keyboard.
                s.quit_games.insert(game_id.clone());
                s.dispatch(
                    Command::GameDisconnected {
                        game: game_id.clone(),
                    },
                    None,
                );
                s.quitting = None;
            }
            Registration::Overlay(id) => {
                info!(overlay = id, "overlay disconnected");
                s.overlays.remove(id);
            }
        }
    }
    drop(tx);
    let _ = writer.await;
    result
}

enum Registration {
    Game(GameId),
    Overlay(u64),
}

/// Translate a wire message into a state-machine command, enforcing that each
/// role only sends its own kind of message.
fn message_to_command(
    msg: ClientMessage,
    registration: &Registration,
) -> Result<Option<Command>, String> {
    let is_game = matches!(registration, Registration::Game(_));
    let command = match msg {
        ClientMessage::Hello { .. } => return Err("already said hello".into()),
        ClientMessage::Participation {
            session,
            instant_join,
        } => match registration {
            Registration::Game(game) => Command::Participation {
                game: game.clone(),
                session,
                instant_join,
            },
            _ => return Err("only games declare participation".into()),
        },
        ClientMessage::ControllerInput {
            session,
            controller,
        } => Command::ControllerInput {
            game: match registration {
                Registration::Game(game) => Some(game.clone()),
                _ => None,
            },
            session,
            controller,
        },

        // Game messages.
        ClientMessage::Ready { session } if is_game => Command::SessionReady { session },
        ClientMessage::Finished { session } if is_game => Command::SessionFinished { session },
        ClientMessage::Progress {
            session,
            percent,
            label,
        } if is_game => Command::SessionProgress {
            session,
            percent,
            label,
        },
        // The one party command a game may send: a player asking to get back
        // out. Everything else stays overlay-only — but somebody stuck inside
        // a game with no way to the lobby can't be rescued by the party
        // either, so this one has to come from the game.
        ClientMessage::RequestOverlay if is_game => Command::OverlayOpened,
        // The mirror of the above, and the reason it has to come from the
        // game: only the game's own process knows the party just switched to
        // its window.
        ClientMessage::RequestStart => match registration {
            Registration::Game(game) => Command::RequestStart { game: game.clone() },
            Registration::Overlay(_) => {
                return Err(
                    "only games report being switched to; overlays use next/play_next".into(),
                )
            }
        },
        ClientMessage::DeclareSettings { settings } => match registration {
            Registration::Game(game) => Command::DeclareSettings {
                game: game.clone(),
                settings,
            },
            Registration::Overlay(_) => return Err("only games declare settings".into()),
        },
        ClientMessage::Ready { .. }
        | ClientMessage::Finished { .. }
        | ClientMessage::Progress { .. } => return Err("only games report session state".into()),
        ClientMessage::RequestOverlay => {
            return Err("only games request the overlay; overlays open it directly".into())
        }

        // Overlay messages.
        _ if is_game => return Err("games cannot send party commands".into()),
        ClientMessage::JoinParty {
            name,
            seat,
            color,
            avatar,
            library,
        } => Command::JoinParty {
            name,
            seat,
            color,
            avatar,
            library,
        },
        ClientMessage::LeaveParty { player_id } => Command::LeaveParty { player_id },
        ClientMessage::RenamePlayer { player_id, name } => {
            Command::RenamePlayer { player_id, name }
        }
        ClientMessage::SetPlayerColor { player_id, color } => {
            Command::SetPlayerColor { player_id, color }
        }
        ClientMessage::SetPlayerAvatar { player_id, avatar } => {
            Command::SetPlayerAvatar { player_id, avatar }
        }
        ClientMessage::AssignSeat { seat, occupant } => Command::AssignSeat { seat, occupant },
        ClientMessage::SwapSeats { a, b } => Command::SwapSeats { a, b },
        ClientMessage::BindController {
            player_id,
            controller,
        } => Command::BindController {
            player_id,
            controller,
        },
        ClientMessage::SetPlaylist { entries } => Command::SetPlaylist { entries },
        ClientMessage::MovePlaylistEntry { expected, from, to } => {
            Command::MovePlaylistEntry { expected, from, to }
        }
        ClientMessage::RemovePlaylistEntry { expected, index } => Command::RemovePlaylistEntry { expected, index },
        ClientMessage::Next => Command::Next,
        ClientMessage::PlayNext { game } => Command::PlayNext { game },
        ClientMessage::Pause => Command::Pause,
        ClientMessage::Resume => Command::Resume,
        ClientMessage::OpenOverlay => Command::OverlayOpened,
        ClientMessage::CloseOverlay => Command::OverlayClosed,
        ClientMessage::Vote { player_id, option } => Command::Vote { player_id, option },
        ClientMessage::SetSetting { game, key, value } => Command::SetSetting { game, key, value },
        ClientMessage::MediaControl { action } => Command::MediaControl { action },
    };
    Ok(Some(command))
}

#[cfg(test)]
mod desktop_lifetime_tests {
    use super::*;

    #[tokio::test]
    async fn desktop_exits_when_lobby_dies_before_hello() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        #[cfg(windows)]
        let launch = serde_json::json!({"command":"cmd.exe", "args":["/C", "exit", "0"]});
        #[cfg(not(windows))]
        let launch = serde_json::json!({"command":"/bin/sh", "args":["-c", "exit 0"]});
        let lobby = serde_json::from_value(serde_json::json!({
            "id":"lobby", "title":"Test", "players":"1", "min_players":1,
            "max_players":1, "emoji":"", "color":"#000000", "launch":launch
        }))
        .unwrap();
        tokio::time::timeout(
            std::time::Duration::from_secs(5),
            run_inner(
                listener,
                vec![lobby],
                Some(GameId::new("lobby")),
                None,
                None,
                false,
                true,
            ),
        )
        .await
        .expect("desktop kept running without its lobby")
        .unwrap();
    }

    #[tokio::test]
    async fn resident_daemon_stays_available_without_lobby() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        assert!(tokio::time::timeout(
            std::time::Duration::from_millis(300),
            run_inner(listener, Vec::new(), None, None, None, false, false)
        )
        .await
        .is_err());
    }
}

#[cfg(test)]
mod local_artwork_tests {
    #[test]
    fn shelf_resolves_packaged_png_and_falls_back_for_missing_art() {
        let root = std::env::temp_dir().join(format!("gamenight-art-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let mut png = vec![0; 33];
        png[..8].copy_from_slice(b"\x89PNG\r\n\x1a\n");
        png[12..16].copy_from_slice(b"IHDR");
        png[16..20].copy_from_slice(&128u32.to_be_bytes());
        png[20..24].copy_from_slice(&128u32.to_be_bytes());
        std::fs::write(root.join("icon.png"), &png).unwrap();
        std::fs::write(root.join("shelf.json"), r##"[{"id":"one","title":"One","cover":"icon.png","color":"#44CCAA"},{"id":"two","title":"Two","cover":"missing.png"},{"id":"three","title":"Three","cover":"../icon.png"}]"##).unwrap();
        let games = super::load_library(root.join("shelf.json").to_str().unwrap()).unwrap();
        assert_eq!(gamenight_protocol::artwork::decode_png_data_uri(games[0].cover.as_ref().unwrap()), Some(png));
        assert_eq!(games[0].color.as_deref(), Some("#44CCAA"));
        assert!(games[1].cover.is_none());
        assert!(games[2].cover.is_none());
        std::fs::remove_dir_all(root).unwrap();
    }
}
