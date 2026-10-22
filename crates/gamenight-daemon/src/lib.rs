//! The GameNight daemon.
//!
//! Owns one [`GameNight`] state machine and speaks the wire protocol to two
//! kinds of WebSocket peers: game processes (SDKs) and overlays. All game
//! logic lives in `gamenight-core`; this crate only does IO — decode incoming
//! messages into [`Command`]s, execute the returned [`Effect`]s.

mod focus;
mod lobby_input;
#[cfg(target_os = "macos")]
mod macos;
mod nowplaying;
#[cfg(windows)]
pub mod windows_launch;

use std::collections::HashMap;
use std::sync::Arc;

use futures_util::{SinkExt, StreamExt};
use tokio::io::AsyncBufReadExt;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, Mutex};
use tokio_tungstenite::tungstenite::Message;
use tracing::{debug, info, warn};

use gamenight_core::{Command, Effect, GameCommand, GameNight, PartyCarry};
use gamenight_protocol::{
    ClientMessage, GameId, GameMeta, LaunchSpec, MediaAction, Role, ServerMessage, SessionId,
    ENV_ADDR, ENV_GAMENIGHT, ENV_GAME_ID, ENV_OVERLAY_URL, ENV_TOKEN, GODOT_SDK_VERSION,
    PROTOCOL_VERSION,
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
/// slowly. The lifetime watchdog reports dead children immediately; failed or timed-out
/// games require an explicit retry.
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
    /// Where players' own settings are saved between nights; `None` keeps
    /// them in memory (tests).
    player_settings_file: Option<std::path::PathBuf>,
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
    /// Titles the daemon stopped itself because the night no longer needed
    /// them (see `retire_idle_games`). Their disconnect is expected: not a
    /// crash to report and not a quit to respect.
    retired: std::collections::HashSet<GameId>,
    game_issues: HashMap<GameId, gamenight_protocol::GameIssueKind>,
    onboarding_error: Option<String>,
    dismissed_onboarding_error: Option<String>,
    /// The background catalogue prewarm, if one is running — lets `launch`
    /// bump a game to the front of the download queue instead of silently
    /// no-oping when there's no launch spec for it yet.
    prewarm: Option<gamenight_installer::PrewarmHandle>,
    /// The party size the prewarm queue was last ordered for, so a seat change
    /// that doesn't change the count doesn't re-sort the queue.
    prewarm_players: Option<u8>,
    /// Packaged app lifetime: quitting the lobby also quits its host.
    exit_with_lobby: bool,
    lobby_game: Option<GameId>,
    /// Pauses the game when the party switches away from its window.
    focus_watch: focus::FocusWatch,
    lobby_token: Option<String>,
    lobby_connections: std::collections::HashSet<GameId>,
    runtime_input: bool,
    /// When a connection (a game's own Back handler, usually) last opened the
    /// overlay. The runtime samples the same physical Back press a few frames
    /// later and must not read it as a second press that closes it again.
    overlay_opened_by_request: Option<std::time::Instant>,
    shutdown_requested: bool,
    lobby_restarts: u8,
    lobby_recovery_opened: bool,
    /// Phone screens declared by connected games, by game.
    companions: HashMap<GameId, gamenight_protocol::CompanionScreen>,
    commands: HashMap<GameId, gamenight_protocol::GameCommands>,
    /// Playtests on this host, by game: the sha256 of the preview build being
    /// installed or on the shelf, and when its install last failed.
    playtests: HashMap<GameId, (String, Option<std::time::Instant>)>,
    /// Files shared with the desktop launcher for updates, when it set them.
    update: Option<HostUpdate>,
    /// The downloaded host version waiting to be applied.
    update_ready: Option<String>,
    update_checked: Option<std::time::Instant>,
    /// Since when nobody has been seated and nothing played, for unattended updates.
    unattended_since: Option<std::time::Instant>,
    /// The launcher's lobby choice files, and the lobbies they offer.
    lobby_paths: Option<gamenight_local_web::host_lobby::Paths>,
    lobbies: Vec<gamenight_protocol::LobbyChoice>,
}

/// The update handoff with the desktop launcher. The launcher downloads in
/// the background and writes `ready`; the daemon decides when (between
/// games), writes the party to `resume` and exits; the launcher applies the
/// update and starts again, covering the screen until `splash` disappears.
#[derive(Debug, Clone)]
pub struct HostUpdate {
    pub ready: std::path::PathBuf,
    pub resume: std::path::PathBuf,
    pub splash: std::path::PathBuf,
}

impl HostUpdate {
    pub fn from_env() -> Option<Self> {
        let path = |key: &str| std::env::var_os(key).map(std::path::PathBuf::from);
        Some(Self {
            ready: path("GAMENIGHT_UPDATE_READY_FILE")?,
            resume: path("GAMENIGHT_RESUME_FILE")?,
            splash: path("GAMENIGHT_UPDATE_SPLASH_FILE")?,
        })
    }
}

/// The process that owns the window in front, and its executable.
#[cfg(windows)]
fn foreground_process() -> Option<(u32, std::path::PathBuf)> {
    use std::os::windows::ffi::OsStringExt;
    use windows_sys::Win32::{
        Foundation::CloseHandle,
        System::Threading::{
            OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32,
            PROCESS_QUERY_LIMITED_INFORMATION,
        },
        UI::WindowsAndMessaging::{GetForegroundWindow, GetWindowThreadProcessId},
    };
    unsafe {
        let window = GetForegroundWindow();
        if window.is_null() {
            return None;
        }
        let mut pid = 0;
        GetWindowThreadProcessId(window, &mut pid);
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
        if process.is_null() {
            return Some((pid, std::path::PathBuf::new()));
        }
        let mut buffer = [0u16; 1024];
        let mut length = buffer.len() as u32;
        let ok = QueryFullProcessImageNameW(
            process,
            PROCESS_NAME_WIN32,
            buffer.as_mut_ptr(),
            &mut length,
        );
        CloseHandle(process);
        let path = if ok == 0 {
            std::path::PathBuf::new()
        } else {
            std::path::PathBuf::from(std::ffi::OsString::from_wide(&buffer[..length as usize]))
        };
        Some((pid, path))
    }
}

/// `pid` and its parents, nearest first. Games launch through a helper (and
/// some through a launcher of their own), so the process the host spawned is
/// often an ancestor of the one that owns the window.
#[cfg(windows)]
fn process_ancestry(pid: u32) -> Vec<u32> {
    use windows_sys::Win32::{
        Foundation::{CloseHandle, INVALID_HANDLE_VALUE},
        System::Diagnostics::ToolHelp::{
            CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
            TH32CS_SNAPPROCESS,
        },
    };
    let mut parents = HashMap::new();
    unsafe {
        let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if snapshot == INVALID_HANDLE_VALUE {
            return vec![pid];
        }
        let mut entry: PROCESSENTRY32W = std::mem::zeroed();
        entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
        if Process32FirstW(snapshot, &mut entry) != 0 {
            loop {
                parents.insert(entry.th32ProcessID, entry.th32ParentProcessID);
                if Process32NextW(snapshot, &mut entry) == 0 {
                    break;
                }
            }
        }
        CloseHandle(snapshot);
    }
    let mut chain = vec![pid];
    while let Some(&parent) = parents.get(chain.last().expect("never empty")) {
        // Parent ids are reused once a parent exits; stop at any loop.
        if parent == 0 || chain.contains(&parent) || chain.len() > 16 {
            break;
        }
        chain.push(parent);
    }
    chain
}

/// Whether the window in front belongs to `executable`.
#[cfg(windows)]
fn foreground_is(executable: &std::path::Path) -> bool {
    let Ok(wanted) = executable.canonicalize() else {
        return false;
    };
    foreground_process()
        .is_some_and(|(_, path)| path.canonicalize().is_ok_and(|path| path == wanted))
}

#[cfg(not(windows))]
fn foreground_is(_executable: &std::path::Path) -> bool {
    false
}

/// How long the lobby waits with everyone asleep (no controller touched for
/// over a minute) before updating on its own.
const UNATTENDED_UPDATE_AFTER: std::time::Duration = std::time::Duration::from_secs(60);

/// Everything written to the resume file. The daemon writes `party`; the
/// process that hosts the phone server adds `web` after the daemon stops.
#[derive(Debug, Default, serde::Serialize, serde::Deserialize)]
pub struct Resume {
    pub party: PartyCarry,
    #[serde(default)]
    pub web: Option<serde_json::Value>,
    /// Set when restarting into another lobby: its title, for the cover.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub lobby: Option<String>,
}

impl Resume {
    /// Read and remove a resume file. A stale one (a crash long ago, a
    /// manual restart the next day) is ignored: the night is over by then.
    pub fn take(path: &std::path::Path) -> Option<Self> {
        let fresh = std::fs::metadata(path)
            .and_then(|meta| meta.modified())
            .ok()
            .and_then(|modified| modified.elapsed().ok())
            .is_some_and(|age| age < std::time::Duration::from_secs(15 * 60));
        let bytes = std::fs::read(path).ok();
        let _ = std::fs::remove_file(path);
        let resume = serde_json::from_slice(&bytes?).ok();
        if !fresh {
            return None;
        }
        resume
    }

    pub fn write(&self, path: &std::path::Path) -> std::io::Result<()> {
        let temporary = path.with_extension("tmp");
        std::fs::write(&temporary, serde_json::to_vec(self)?)?;
        std::fs::rename(temporary, path)
    }
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
            retired: std::collections::HashSet::new(),
            game_issues: HashMap::new(),
            onboarding_error: None,
            dismissed_onboarding_error: None,
            prewarm,
            // A fresh night genuinely has nobody seated, so recording that up
            // front keeps the first real join the first signal ever sent.
            prewarm_players: Some(0),
            exit_with_lobby: false,
            player_settings_file: None,
            lobby_game: None,
            focus_watch: Default::default(),
            lobby_token: None,
            lobby_connections: Default::default(),
            runtime_input: false,
            overlay_opened_by_request: None,
            shutdown_requested: false,
            lobby_restarts: 0,
            lobby_recovery_opened: false,
            companions: HashMap::new(),
            commands: HashMap::new(),
            playtests: HashMap::new(),
            update: None,
            update_ready: None,
            update_checked: None,
            unattended_since: None,
            lobby_paths: None,
            lobbies: Vec::new(),
        }
    }

    fn snapshot(&self) -> gamenight_protocol::PartySnapshot {
        let mut party = self.night.snapshot();
        party.onboarding_error = self.onboarding_error.clone();
        party.game_issues = self
            .game_issues
            .iter()
            .map(|(game, kind)| gamenight_protocol::GameIssue {
                game: game.clone(),
                kind: kind.clone(),
            })
            .collect();
        party.game_issues.sort_by(|a, b| a.game.0.cmp(&b.game.0));
        party.companions = self.companions.values().cloned().collect();
        party.companions.sort_by(|a, b| a.game.0.cmp(&b.game.0));
        party.commands = self.commands.values().cloned().collect();
        party.commands.sort_by(|a, b| a.game.0.cmp(&b.game.0));
        party.update_ready = self.update_ready.clone();
        party.lobbies = self.lobbies.clone();
        party
    }

    /// Re-read the launcher's "update downloaded" note now and then.
    fn refresh_update_ready(&mut self) {
        let Some(update) = &self.update else { return };
        let now = std::time::Instant::now();
        if self
            .update_checked
            .is_some_and(|at| now.duration_since(at) < std::time::Duration::from_secs(5))
        {
            return;
        }
        self.update_checked = Some(now);
        let version = std::fs::read(&update.ready)
            .ok()
            .filter(|bytes| bytes.len() <= 4096)
            .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
            .and_then(|value| value["version"].as_str().map(str::to_owned));
        if version != self.update_ready {
            info!(?version, "host update readiness changed");
            self.update_ready = version;
            self.broadcast_party();
        }
    }

    /// Restart into the downloaded update if nothing is being played. The
    /// party is written for the next process; the launcher does the rest.
    fn restart_for_update(&mut self) -> Result<(), String> {
        if self.update.is_none() {
            return Err("this host cannot update itself".into());
        }
        if self.update_ready.is_none() {
            return Err("no update is ready".into());
        }
        if !self.lobby_on_screen() {
            return Err("finish the current game before updating".into());
        }
        self.restart_with_party(None)?;
        info!("restarting into a host update; party saved");
        Ok(())
    }

    /// Stop so the launcher starts the host again, with this party.
    fn restart_with_party(&mut self, lobby: Option<String>) -> Result<(), String> {
        let Some(update) = &self.update else {
            return Err("this host cannot restart itself".into());
        };
        let resume = Resume {
            party: self.night.carry(),
            web: None,
            lobby,
        };
        resume
            .write(&update.resume)
            .map_err(|error| format!("could not save the party: {error}"))?;
        self.shutdown_requested = true;
        Ok(())
    }

    /// Re-read which lobbies the launcher offers; the running one is current.
    fn refresh_lobbies(&mut self) {
        let Some((config, registrations, bundled)) = &self.lobby_paths else {
            return;
        };
        let mut lobbies =
            gamenight_local_web::host_lobby::list(config, registrations, bundled.as_deref());
        for lobby in &mut lobbies {
            lobby.current = self.lobby_game.as_ref() == Some(&lobby.id);
        }
        // One lobby is nothing to switch between.
        if lobbies.len() < 2 {
            lobbies.clear();
        }
        if lobbies != self.lobbies {
            self.lobbies = lobbies;
            self.broadcast_party();
        }
    }

    /// Make `lobby` the host's lobby and restart into it with the party.
    /// A host that cannot restart itself uses it from its next start.
    fn switch_lobby(&mut self, lobby: &GameId) -> Result<(), String> {
        self.refresh_lobbies();
        let Some((config, registrations, bundled)) = &self.lobby_paths else {
            return Err("this host cannot switch lobbies".into());
        };
        let Some(choice) = self.lobbies.iter().find(|l| &l.id == lobby).cloned() else {
            return Err("that lobby is not installed".into());
        };
        if choice.current {
            return Ok(());
        }
        if !self.night.between_games() {
            return Err("finish the current game before switching lobbies".into());
        }
        let saved = gamenight_local_web::host_lobby::save(
            config,
            registrations,
            bundled.as_deref(),
            &lobby.0,
        )
        .map_err(|error| format!("could not save the lobby: {error}"))?;
        if !saved {
            return Err("that lobby is not installed".into());
        }
        if self.update.is_none() {
            return Err(format!(
                "{} opens the next time you start GameNight",
                choice.title
            ));
        }
        self.restart_with_party(Some(choice.title))?;
        info!(%lobby, "restarting into another lobby; party saved");
        Ok(())
    }

    /// Nobody is pulled out of a game by a restart. The night's own state
    /// knows when the lobby took over; a game left running behind it (the
    /// party switched windows, or the game went back without telling us)
    /// only shows on the desktop, so ask Windows which window is in front.
    fn lobby_on_screen(&self) -> bool {
        if self.night.between_games() {
            return true;
        }
        let Some(lobby) = self.lobby_game.as_ref() else {
            return false;
        };
        let Some(spec) = self.launch_specs.get(lobby) else {
            return false;
        };
        foreground_is(std::path::Path::new(&spec.command))
    }

    /// Alt+Tab away from the game pauses it and hands the controllers to
    /// the lobby; switching back to the game resumes it. See [`focus`].
    fn watch_focus(&mut self) {
        let active = self
            .night
            .active_session()
            .map(|(game, session, phase)| (game.clone(), session, phase));
        let watching = active.as_ref().is_some_and(|(_, _, phase)| {
            *phase == gamenight_protocol::SessionPhase::Running
                || (*phase == gamenight_protocol::SessionPhase::Paused
                    && self.focus_watch.paused_by_us())
        });
        let front = match &active {
            Some((game, _, _)) if watching => self.front(game),
            _ => focus::Front::Neutral,
        };
        let step = self.focus_watch.step(
            std::time::Instant::now(),
            active
                .as_ref()
                .map(|(_, session, phase)| (*session, *phase)),
            front,
        );
        match step {
            Some(focus::FocusAction::Pause) => {
                info!("the game lost the screen (Alt+Tab); pausing it for the lobby");
                self.dispatch(Command::OverlayOpened, None);
            }
            Some(focus::FocusAction::Resume) => {
                info!("the party switched back to the game; resuming it");
                if self.night.snapshot().overlay_open {
                    self.dispatch(Command::OverlayClosed, None);
                }
            }
            None => {}
        }
    }

    /// Whose window is in front, from the point of view of `game`.
    #[cfg(windows)]
    fn front(&self, game: &GameId) -> focus::Front {
        let Some((pid, path)) = foreground_process() else {
            return focus::Front::Neutral;
        };
        let ancestry = process_ancestry(pid);
        let path = path.canonicalize().ok();
        let owns = |id: &GameId| {
            let spawned = self
                .running_children
                .get(id)
                .or_else(|| self.pending_launches.get(id).map(|p| &p.child))
                .and_then(|child| child.id());
            spawned.is_some_and(|child| ancestry.contains(&child))
                || self.launch_specs.get(id).is_some_and(|spec| {
                    path.is_some()
                        && std::path::Path::new(&spec.command).canonicalize().ok() == path
                })
        };
        if owns(game) {
            return focus::Front::Game;
        }
        let other_game = self
            .running_children
            .keys()
            .chain(self.pending_launches.keys())
            .any(|id| Some(id) != self.lobby_game.as_ref() && owns(id));
        if other_game {
            focus::Front::Neutral
        } else {
            focus::Front::Other
        }
    }

    /// Nothing to ask outside Windows: macOS games report Cmd+Tab
    /// themselves with `request_start`.
    #[cfg(not(windows))]
    fn front(&self, _game: &GameId) -> focus::Front {
        focus::Front::Neutral
    }

    /// A quiet lobby updates by itself: nobody bothered, party kept.
    fn maybe_update_unattended(&mut self) {
        let idle = self.update_ready.is_some()
            && self.night.couch_idle()
            && self.lobby_on_screen()
            && !self.shutdown_requested;
        if !idle {
            self.unattended_since = None;
            return;
        }
        let since = *self
            .unattended_since
            .get_or_insert_with(std::time::Instant::now);
        if since.elapsed() >= UNATTENDED_UPDATE_AFTER {
            if let Err(error) = self.restart_for_update() {
                warn!(%error, "unattended update skipped");
                self.unattended_since = None;
            }
        }
    }

    fn record_game_issue(&mut self, game: GameId, kind: gamenight_protocol::GameIssueKind) {
        self.quit_games.insert(game.clone());
        self.game_issues.insert(game.clone(), kind);
        self.quitting = Some(game.clone());
        self.dispatch(Command::GameDisconnected { game }, None);
        self.quitting = None;
    }

    fn refresh_onboarding_error(&mut self, file: &std::path::Path) {
        // Host-written file, never a report accepted from a game.
        let error = std::fs::read(file)
            .ok()
            .filter(|bytes| bytes.len() <= 8192)
            .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok())
            .filter(|saved| saved["complete"] == false && saved["game"].is_string())
            .and_then(|saved| {
                saved["error"]
                    .as_str()
                    .map(|s| s.chars().take(300).collect::<String>())
            });
        if error.is_none() {
            self.dismissed_onboarding_error = None;
        }
        let visible = error.filter(|error| Some(error) != self.dismissed_onboarding_error.as_ref());
        if self.onboarding_error != visible {
            self.onboarding_error = visible;
            self.apply_effects(vec![Effect::StateChanged], None);
        }
    }

    /// Check launches even when no UI command arrives. Lobby recovery has its
    /// own watchdog; games stay stopped until the party deliberately retries.
    fn poll_pending_games(&mut self) {
        use gamenight_protocol::GameIssueKind;
        let mut ended = Vec::new();
        for (game, pending) in &mut self.pending_launches {
            if self.lobby_game.as_ref() == Some(game) {
                continue;
            }
            match pending.child.try_wait() {
                Ok(Some(status)) => {
                    warn!(%game, %status, "game exited before connecting");
                    ended.push((game.clone(), GameIssueKind::FailedToStart));
                }
                Ok(None) if pending.spawned_at.elapsed() > LAUNCH_HELLO_TIMEOUT => {
                    ended.push((game.clone(), GameIssueKind::StartupTimeout));
                }
                Err(error) => warn!(%game, %error, "could not inspect game process"),
                _ => {}
            }
        }
        for (game, kind) in ended {
            if let Some(mut pending) = self.pending_launches.remove(&game) {
                let _ = pending.child.start_kill();
                tokio::spawn(async move {
                    let _ = pending.child.wait().await;
                });
            }
            self.record_game_issue(game, kind);
        }
    }

    /// Keep the download queue pointed at games this many people can actually
    /// play. Called after every command, because "how many are playing" is
    /// answered by people picking up controllers throughout the evening, not
    /// once at boot — the fourth person arriving should change what's
    /// downloading next, not just what's playable now.
    fn sync_prewarm_players(&mut self) {
        let Some(prewarm) = &self.prewarm else { return };
        let players = self.snapshot().players.len().min(u8::MAX as usize) as u8;
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
        if matches!(command, Command::OverlayOpened)
            && origin.is_some()
            && !self.night.snapshot().overlay_open
        {
            self.overlay_opened_by_request = Some(std::time::Instant::now());
        }
        if matches!(
            &command,
            Command::PlayNext { .. }
                | Command::QueueNext { .. }
                | Command::QueueGame { .. }
                | Command::RequestStart { .. }
                | Command::Next
        ) {
            if let Some(error) = self.onboarding_error.take() {
                self.dismissed_onboarding_error = Some(error);
                self.apply_effects(vec![Effect::StateChanged], None);
            }
        }
        let previous_music = self.night.now_playing().cloned();
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
            Command::PlayNext { game }
            | Command::QueueNext { game }
            | Command::QueueGame { game, .. }
            | Command::RequestStart { game } => {
                self.game_issues.remove(game);
                if self.quit_games.remove(game) {
                    info!(%game, "the party asked for it again — it may start");
                }
            }
            Command::Next if !self.quit_games.is_empty() => {
                let party = self.night.snapshot();
                if let Some(game) = party
                    .warm_session
                    .map(|s| s.game)
                    .or_else(|| party.warming.map(|entry| entry.game))
                {
                    self.quit_games.remove(&game);
                    self.game_issues.remove(&game);
                }
            }
            _ => {}
        }
        if let Command::PlayNext { game }
        | Command::QueueNext { game }
        | Command::QueueGame { game, .. } = &command
        {
            if !self.launch_specs.contains_key(game) {
                if let Some(prewarm) = &self.prewarm {
                    info!(%game, "playing an uninstalled catalogue game — bumping the prewarm queue");
                    prewarm.prioritize(game.0.clone());
                }
            }
        }
        let effects = self.night.handle(command);
        self.apply_effects(effects, origin);
        // Games need live host-music state, including pause/stop, so they
        // can yield only their soundtrack. Do not stream large catalog art
        // or every unrelated party update to background games.
        if self.night.now_playing() != previous_music.as_ref() {
            for (id, tx) in &self.games {
                if !self.lobby_connections.contains(id) {
                    send(
                        tx,
                        &ServerMessage::PartyState {
                            party: self.game_snapshot(id),
                        },
                    );
                }
            }
        }
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
                Effect::PlayerSettings {
                    game,
                    player_id,
                    values,
                } => {
                    if let Some(tx) = self.games.get(&game) {
                        send(
                            tx,
                            &ServerMessage::PlayerSettings {
                                game,
                                player_id,
                                values,
                            },
                        );
                    }
                }
                Effect::PlayerSettingsStored => self.save_player_settings(),
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
                    } else if action == MediaAction::Resume {
                        // Nothing on yet: start the player the host used last.
                        tokio::spawn(nowplaying::resume_last());
                    }
                }
                Effect::PartyOver => {
                    info!("the party voted to quit — good night!");
                    self.kill_all_children();
                    broadcast = true;
                }
                Effect::SettingsAccepted {
                    game,
                    session,
                    revision,
                } => {
                    if let Some(tx) = origin {
                        send(
                            tx,
                            &ServerMessage::SettingsAccepted {
                                game,
                                session,
                                revision,
                            },
                        );
                    }
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
            self.broadcast_party();
        }
        self.retire_idle_games();
    }

    /// Stop game processes we launched that the night no longer needs. Only
    /// the game being played and the next one stay loaded: changing the next
    /// game over and over, or a long queue, must not leave every game it
    /// touched running (seven at once, 650 MB each, on a living room PC).
    /// A retired game launches again when its turn comes.
    fn retire_idle_games(&mut self) {
        let wanted = self.night.wanted_games();
        let idle: Vec<GameId> = self
            .running_children
            .keys()
            .chain(self.pending_launches.keys())
            .filter(|game| !wanted.contains(game) && self.lobby_game.as_ref() != Some(*game))
            .cloned()
            .collect();
        for game in idle {
            let child = self
                .running_children
                .remove(&game)
                .or_else(|| self.pending_launches.remove(&game).map(|p| p.child));
            let Some(mut child) = child else { continue };
            info!(%game, "stopping a game the night no longer needs");
            if self.games.contains_key(&game) {
                self.retired.insert(game.clone());
            }
            let _ = child.start_kill();
            tokio::spawn(async move {
                let _ = child.wait().await;
            });
        }
    }

    fn broadcast_party(&self) {
        let msg = ServerMessage::PartyState {
            party: self.snapshot(),
        };
        for tx in self.overlays.values() {
            send(tx, &msg);
        }
        let lobby_msg = ServerMessage::PartyState {
            party: lobby_snapshot(self.snapshot()),
        };
        for id in &self.lobby_connections {
            if let Some(tx) = self.games.get(id) {
                send(tx, &lobby_msg);
            }
        }
    }

    /// Route plain-text requests: a game declares what it understands, the
    /// local web server asks on behalf of a seated player, the game answers.
    fn game_command(&mut self, msg: ClientMessage, registration: &Registration, tx: &Tx) {
        let reject = |message: &str| {
            send(
                tx,
                &ServerMessage::Error {
                    message: message.into(),
                },
            )
        };
        match (msg, registration) {
            (
                ClientMessage::DeclareCommands {
                    description,
                    examples,
                },
                Registration::Game(game),
            ) => {
                if description.len() > 2000
                    || examples.len() > 20
                    || examples.iter().any(|e| e.len() > 200)
                {
                    return reject("command declaration too long");
                }
                info!(%game, "game accepts plain-text requests");
                self.commands.insert(
                    game.clone(),
                    gamenight_protocol::GameCommands {
                        game: game.clone(),
                        description,
                        examples,
                    },
                );
                self.broadcast_party();
            }
            (
                ClientMessage::GameCommand {
                    game,
                    player_id,
                    id,
                    text,
                },
                Registration::Overlay(_),
            ) => {
                if id.is_empty() || id.len() > 64 || text.trim().is_empty() || text.len() > 500 {
                    return reject("invalid game command");
                }
                if !self.commands.contains_key(&game) {
                    return reject("that game does not accept requests");
                }
                if !self
                    .night
                    .snapshot()
                    .players
                    .iter()
                    .any(|p| p.id == player_id)
                {
                    return reject("unknown player");
                }
                if let Some(game_tx) = self.games.get(&game) {
                    send(
                        game_tx,
                        &ServerMessage::GameCommand {
                            game,
                            player_id,
                            id,
                            text,
                        },
                    );
                }
            }
            (ClientMessage::CommandResult { id, ok, message }, Registration::Game(game)) => {
                let msg = ServerMessage::CommandResult {
                    game: game.clone(),
                    id,
                    ok,
                    message: message.chars().take(1000).collect(),
                };
                for overlay in self.overlays.values() {
                    send(overlay, &msg);
                }
            }
            (ClientMessage::DeclareCommands { .. } | ClientMessage::CommandResult { .. }, _) => {
                reject("only games declare and answer requests")
            }
            _ => reject("only the local web server sends game commands"),
        }
    }

    /// Route phone screen traffic. Games publish their screen and talk to
    /// phones; the local web server (an overlay) relays what phones send.
    fn companion(&mut self, msg: ClientMessage, registration: &Registration, tx: &Tx) {
        let reject = |message: &str| {
            send(
                tx,
                &ServerMessage::Error {
                    message: message.into(),
                },
            )
        };
        match (msg, registration) {
            (ClientMessage::DeclareCompanion { root, entry, app }, Registration::Game(game)) => {
                let screen = gamenight_protocol::CompanionScreen {
                    game: game.clone(),
                    entry,
                    root,
                    app,
                };
                if let Err(reason) = valid_companion(&screen) {
                    return reject(reason);
                }
                info!(%game, ?screen, "game declared a phone screen");
                self.companions.insert(game.clone(), screen);
                self.broadcast_party();
            }
            (
                ClientMessage::CompanionMessage {
                    player_id, data, ..
                },
                Registration::Game(game),
            ) => {
                let msg = ServerMessage::CompanionMessage {
                    game: game.clone(),
                    player_id,
                    data,
                };
                for overlay in self.overlays.values() {
                    send(overlay, &msg);
                }
            }
            (
                ClientMessage::CompanionMessage {
                    game: Some(game),
                    player_id: Some(player_id),
                    data,
                },
                Registration::Overlay(_),
            ) => {
                if let Some(game_tx) = self.games.get(&game) {
                    send(
                        game_tx,
                        &ServerMessage::CompanionMessage {
                            game,
                            player_id: Some(player_id),
                            data,
                        },
                    );
                }
            }
            (
                ClientMessage::CompanionPresence {
                    game,
                    player_id,
                    connected,
                },
                Registration::Overlay(_),
            ) => {
                if let Some(game_tx) = self.games.get(&game) {
                    send(
                        game_tx,
                        &ServerMessage::CompanionPresence {
                            player_id,
                            connected,
                        },
                    );
                }
            }
            (ClientMessage::DeclareCompanion { .. }, _) => {
                reject("only games declare a phone screen")
            }
            (ClientMessage::CompanionPresence { .. }, _) => {
                reject("only the local web server reports phone screens")
            }
            _ => reject("companion_message from a phone needs game and player_id"),
        }
    }

    /// Write players' own settings, replacing the file atomically. A failed
    /// write keeps tonight's values in memory and is logged.
    fn save_player_settings(&self) {
        let Some(path) = &self.player_settings_file else {
            return;
        };
        let write = || -> std::io::Result<()> {
            if let Some(dir) = path.parent() {
                std::fs::create_dir_all(dir)?;
            }
            let temporary = path.with_extension("tmp");
            std::fs::write(
                &temporary,
                serde_json::to_vec_pretty(&serde_json::json!({
                    "version": 1,
                    "players": self.night.saved_player_settings(),
                }))?,
            )?;
            std::fs::rename(temporary, path)
        };
        if let Err(error) = write() {
            warn!(%error, path = %path.display(), "could not save player settings");
        }
    }

    /// Send every player's own settings to `game`, after a roster message.
    fn send_player_settings(&self, game: &GameId, players: &[gamenight_protocol::Player]) {
        let Some(tx) = self.games.get(game) else {
            return;
        };
        for player in players {
            if let Some(values) = self.night.player_settings(game, player.id) {
                send(
                    tx,
                    &ServerMessage::PlayerSettings {
                        game: game.clone(),
                        player_id: player.id,
                        values,
                    },
                );
            }
        }
    }

    /// Fill in each player's per-game profile key; only games see these.
    fn add_profile_keys(&self, game: &GameId, players: &mut [gamenight_protocol::Player]) {
        for player in players {
            player.profile_key = self.night.profile_key(game, player.id);
        }
    }

    /// The party as a game process sees it.
    fn game_snapshot(&self, game: &GameId) -> gamenight_protocol::PartySnapshot {
        let mut party = game_welcome_snapshot(self.snapshot());
        self.add_profile_keys(game, &mut party.players);
        party
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
                mut players,
                presence,
            } => {
                self.add_profile_keys(game, &mut players);
                ServerMessage::PartyUpdated {
                    session,
                    seats,
                    players,
                    presence,
                }
            }
            GameCommand::Prepare { seats, mut players } => {
                self.add_profile_keys(game, &mut players);
                ServerMessage::Prepare {
                    session,
                    game: game.clone(),
                    seats,
                    players,
                }
            }
            GameCommand::PlayersUpdated { mut players } => {
                self.add_profile_keys(game, &mut players);
                ServerMessage::PlayersUpdated { session, players }
            }
            GameCommand::Start => ServerMessage::Start { session },
            GameCommand::Pause => ServerMessage::Pause { session },
            GameCommand::Resume => ServerMessage::Resume { session },
            GameCommand::Dispose => ServerMessage::Dispose { session },
        };
        send(tx, &msg);
        if let ServerMessage::Prepare { players, .. }
        | ServerMessage::PartyUpdated { players, .. } = &msg
        {
            self.send_player_settings(game, players);
        }
    }

    /// Spawn the process for `game` per its launch spec, unless one is
    /// already connected or a spawn is in flight.
    fn launch(&mut self, game: &GameId) {
        if self.games.contains_key(game) {
            return;
        }
        if self.pending_launches.contains_key(game) {
            return; // The lifetime watchdog owns failed/expired launches.
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
        #[cfg(windows)]
        {
            // Console wrappers and native games must be quiet before hello.
            // Preserve direct lobby launch: it is the window the user wants.
            let batch = std::path::Path::new(&spec.command)
                .extension()
                .is_some_and(|ext| {
                    ext.eq_ignore_ascii_case("cmd") || ext.eq_ignore_ascii_case("bat")
                });
            if self.lobby_game.as_ref() != Some(game) && !batch {
                if let Ok(exe) = std::env::current_exe() {
                    // Library embedders (including test harnesses) do not
                    // necessarily implement the daemon's helper entrypoint.
                    if exe
                        .file_stem()
                        .is_some_and(|name| name.eq_ignore_ascii_case("gamenight-daemon"))
                    {
                        cmd = tokio::process::Command::new(exe);
                        cmd.arg("--launch-hidden").arg(&spec.command);
                    }
                }
            }
            cmd.creation_flags(windows_sys::Win32::System::Threading::CREATE_NO_WINDOW);
        }
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
        // Lobbies that cannot call user32 (Godot) run us with
        // --allow-foreground to hand the screen to a warm game.
        #[cfg(windows)]
        if let Ok(exe) = std::env::current_exe() {
            cmd.env("GAMENIGHT_FOREGROUND_HELPER", exe);
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
            Err(e) => {
                warn!(%game, command = %spec.command, error = %e, "failed to launch");
                self.record_game_issue(
                    game.clone(),
                    gamenight_protocol::GameIssueKind::FailedToStart,
                );
            }
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

// Games need party identity and settings, not the lobby's embedded catalog art.
// Keep Welcome within lightweight clients' frame limits as the catalog grows.
fn game_welcome_snapshot(
    mut party: gamenight_protocol::PartySnapshot,
) -> gamenight_protocol::PartySnapshot {
    for game in &mut party.library {
        game.cover = None;
        game.icon = None;
        game.screenshot = None;
    }
    // A game only needs its own screen, not where other games live on disk.
    party.companions.clear();
    party
}

// The lobby renders catalogue metadata. Commands, local paths and arbitrary
// launch environment values stay inside the runtime.
fn lobby_snapshot(
    mut party: gamenight_protocol::PartySnapshot,
) -> gamenight_protocol::PartySnapshot {
    for game in &mut party.library {
        game.launch = None;
    }
    for companion in &mut party.companions {
        companion.root = None;
    }
    party
}

/// A file path a phone may ask for inside a declared root.
fn relative_path(path: &str) -> bool {
    !path.is_empty()
        && !path.starts_with(['/', '\\'])
        && !path.contains(':')
        && !path.split(['/', '\\']).any(|part| part == "..")
}

fn valid_companion(screen: &gamenight_protocol::CompanionScreen) -> Result<(), &'static str> {
    if let Some(root) = &screen.root {
        if !std::path::Path::new(root).is_absolute() {
            return Err("declare_companion: root must be an absolute directory");
        }
    }
    if let Some(entry) = &screen.entry {
        if screen.root.is_none() || !relative_path(entry) {
            return Err("declare_companion: entry must be a relative page inside root");
        }
    }
    if let Some(app) = &screen.app {
        let name_ok = !app.name.trim().is_empty() && app.name.len() <= 80;
        let package_ok = app.android.as_deref().is_none_or(|p| {
            !p.is_empty()
                && p.len() <= 200
                && p.chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '_')
        });
        let download_ok = app.download.as_deref().is_none_or(|d| {
            d.starts_with("https://") || (screen.root.is_some() && relative_path(d))
        });
        if !name_ok || !package_ok || !download_ok {
            return Err("declare_companion: app needs a name, a package id and an https or in-root download");
        }
    }
    if screen.entry.is_none() && screen.app.is_none() {
        return Err("declare_companion needs an entry page, an app, or both");
    }
    Ok(())
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
                    let mut s = shared.lock().await;
                    // An explicit shelf entry belongs to this running host. A
                    // background catalogue refresh must not replace its launch
                    // command with a different build while people are playing.
                    if s.launch_specs.contains_key(&meta.id) {
                        info!(game = %status.game, "background install kept explicit shelf entry");
                    } else {
                        info!(game = %status.game, "background install joined the shelf");
                        if let Some(launch) = &meta.launch {
                            s.launch_specs.insert(meta.id.clone(), launch.clone());
                        }
                        let fx = s.night.add_to_library(meta);
                        s.apply_effects(fx, None);
                    }
                }
            }
            let mut s = shared.lock().await;
            let fx = s.night.handle(Command::InstallProgress { status });
            s.apply_effects(fx, None);
        }
    });
}

/// How long a failed playtest download waits before the next poll retries it.
const PLAYTEST_RETRY: std::time::Duration = std::time::Duration::from_secs(60);

/// The tagline that marks a preview build. The title stays the game's own:
/// a "(playtest)" suffix on the shelf only puzzled people.
fn playtest_entry(
    mut entry: gamenight_catalog::CatalogEntry,
    version: Option<&String>,
) -> gamenight_catalog::CatalogEntry {
    entry.tagline = Some(match version {
        Some(version) => format!("Test build {version}, newer than the store version"),
        None => "Test build, newer than the store version".into(),
    });
    entry
}

/// Local shelf entries and playtests often carry no artwork of their own.
/// Fill in what they lack from the catalogue entry with the same id, so a
/// game looks the same on the shelf however it got there.
pub fn add_catalog_art(library: &mut [GameMeta], catalog: &[gamenight_catalog::CatalogEntry]) {
    for game in library {
        let Some(entry) = catalog.iter().find(|e| e.id == game.id.0) else {
            continue;
        };
        for (art, from) in [
            (&mut game.cover, &entry.cover),
            (&mut game.icon, &entry.icon),
            (&mut game.screenshot, &entry.screenshot),
        ] {
            if art.as_deref().is_none_or(str::is_empty) {
                art.clone_from(from);
            }
        }
    }
}

/// [`add_catalog_art`] from the catalogue this host reads.
fn with_catalog_art(mut meta: GameMeta) -> GameMeta {
    let catalog =
        gamenight_catalog::load_dir(&gamenight_catalog::catalog_dir()).unwrap_or_default();
    add_catalog_art(std::slice::from_mut(&mut meta), &catalog);
    meta
}

/// Install a playtest the cloud announced and put it on the shelf, replacing
/// a released version of the same game for the rest of the night. Repeated
/// announcements of the same build do nothing; a new preview build replaces
/// the old one once it is installed. The playtest stays on the shelf until the
/// host restarts, even when the tester leaves the table.
fn start_playtest(
    s: &mut Shared,
    shared: &Arc<Mutex<Shared>>,
    playtest: gamenight_protocol::Playtest,
) {
    let platform = gamenight_catalog::current_platform();
    let entry = match serde_json::from_value::<gamenight_catalog::CatalogEntry>(playtest.entry) {
        Ok(entry) => entry,
        Err(error) => {
            warn!(%error, "ignoring a playtest with an invalid catalogue entry");
            return;
        }
    };
    let game = GameId::new(&entry.id);
    if s.lobby_game.as_ref() == Some(&game) || entry.id == "lobby" {
        return;
    }
    let Some(sha256) = entry
        .downloads
        .get(platform)
        .map(|d| d.sha256.to_ascii_lowercase())
    else {
        return;
    };
    match s.playtests.get(&game) {
        Some((known, None)) if *known == sha256 => return,
        Some((known, Some(failed))) if *known == sha256 && failed.elapsed() < PLAYTEST_RETRY => {
            return
        }
        _ => {}
    }
    s.playtests.insert(game.clone(), (sha256.clone(), None));
    let entry = playtest_entry(entry, playtest.versions.get(platform));
    let grant = playtest.grant;
    let shared = shared.clone();
    info!(%game, "installing a playtest build");
    tokio::spawn(async move {
        let root = gamenight_installer::install_dir().join(".playtests");
        let (reporter, mut progress) = gamenight_installer::progress_channel();
        let forward = {
            let shared = shared.clone();
            tokio::spawn(async move {
                while let Some(status) = progress.recv().await {
                    let mut s = shared.lock().await;
                    let fx = s.night.handle(Command::InstallProgress { status });
                    s.apply_effects(fx, None);
                }
            })
        };
        let result =
            gamenight_installer::ensure_playtest_installed(&entry, &root, &grant, Some(&reporter))
                .await;
        drop(reporter);
        let _ = forward.await;
        let mut s = shared.lock().await;
        // A newer build may have been announced while this one downloaded.
        if s.playtests.get(&game).map(|p| &p.0) != Some(&sha256) {
            return;
        }
        match result {
            Ok(installed) => {
                let meta = with_catalog_art(gamenight_installer::game_meta(&entry, &installed));
                info!(%game, "playtest build joined the shelf");
                if let Some(launch) = &meta.launch {
                    s.launch_specs.insert(game.clone(), launch.clone());
                }
                let fx = s.night.add_to_library(meta);
                s.apply_effects(fx, None);
            }
            Err(error) => {
                warn!(%game, %error, "playtest install failed");
                s.playtests
                    .insert(game, (sha256, Some(std::time::Instant::now())));
            }
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
    // Reported installed, so a paid game had its grant: accept its download.
    let installed = gamenight_installer::already_installed_granted(entry, root).await?;
    Some(gamenight_installer::game_meta(entry, &installed))
}

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

/// The development shelf, used when `GAMENIGHT_LIBRARY` is not set. Exactly
/// one entry, and it is one the daemon can actually start.
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
        icon: None,
        screenshot: None,
        color: Some("#3ddc97".into()),
        emoji: Some("🎲".into()),
        players: Some("1–4".into()),
        min_players: Some(1),
        max_players: Some(4),
        best_players: Some(2),
        play_with: Default::default(),
        min_phones: None,
        launch: demo_game_launch(),
    }]
}

/// Load the shelf from a JSON file (an array of `GameMeta`).
pub fn load_library(path: &str) -> std::io::Result<Vec<GameMeta>> {
    let text = std::fs::read_to_string(path)?;
    let mut library: Vec<GameMeta> = serde_json::from_str(&text).map_err(|e| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("bad library file {path}: {e}"),
        )
    })?;
    let root = std::path::Path::new(path)
        .parent()
        .unwrap_or(std::path::Path::new("."));
    for game in &mut library {
        for artwork in [&mut game.cover, &mut game.icon, &mut game.screenshot] {
            if let Some(cover) = artwork
                .clone()
                .filter(|cover| !cover.contains("://") && !cover.starts_with("data:"))
            {
                let relative = std::path::Path::new(&cover);
                let safe = !relative.is_absolute()
                    && relative.components().all(|part| {
                        matches!(
                            part,
                            std::path::Component::Normal(_) | std::path::Component::CurDir
                        )
                    });
                *artwork = if safe {
                    std::fs::File::open(root.join(relative))
                        .ok()
                        .and_then(|file| {
                            use std::io::Read;
                            let mut bytes = Vec::new();
                            file.take((gamenight_protocol::artwork::MAX_PNG_BYTES + 1) as u64)
                                .read_to_end(&mut bytes)
                                .ok()?;
                            gamenight_protocol::artwork::png_data_uri(&bytes)
                        })
                } else {
                    None
                };
                if artwork.is_none() {
                    tracing::warn!(game = ?game.id, "cover unavailable; using title/color fallback");
                }
            }
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

/// Let any process take the foreground, until the next user input. Started as
/// a child of the foreground lobby right before it asks for a game, so the
/// warm game window can come to the front (Windows only; a no-op elsewhere).
pub fn allow_any_foreground() {
    #[cfg(windows)]
    {
        #[link(name = "user32")]
        extern "system" {
            fn AllowSetForegroundWindow(process_id: u32) -> i32;
        }
        // ASFW_ANY: the protocol has no process IDs to name.
        unsafe {
            AllowSetForegroundWindow(u32::MAX);
        }
    }
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
    run_inner(listener, library, lobby_game, prewarm, None, false, None).await
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
        None,
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
    update: Option<HostUpdate>,
    carry: Option<PartyCarry>,
) -> std::io::Result<()> {
    run_inner(
        listener,
        library,
        Some(lobby_game),
        prewarm,
        install_progress,
        true,
        Some(Desktop { update, carry }),
    )
    .await
}

/// The file players' own settings are kept in between nights.
#[derive(serde::Deserialize)]
struct SavedPlayerSettings {
    version: u32,
    #[serde(default)]
    players: gamenight_core::PlayerSettingsStore,
}

/// `GAMENIGHT_PLAYER_SETTINGS`, else `gamenight/player-settings.json` in the
/// user data directory (next to the remembered players) for the evening's
/// daemon; test daemons keep settings in memory.
fn player_settings_path(real: bool) -> Option<std::path::PathBuf> {
    if let Some(path) = std::env::var_os("GAMENIGHT_PLAYER_SETTINGS") {
        return Some(path.into());
    }
    if !real {
        return None;
    }
    let root = std::env::var_os("LOCALAPPDATA")
        .map(std::path::PathBuf::from)
        .or_else(|| std::env::var_os("XDG_DATA_HOME").map(std::path::PathBuf::from))
        .unwrap_or_else(|| {
            std::path::PathBuf::from(std::env::var_os("HOME").unwrap_or_default())
                .join(".local/share")
        });
    Some(root.join("gamenight/player-settings.json"))
}

/// What only the packaged desktop app has: quitting with its lobby, and
/// updating itself without losing the party.
struct Desktop {
    update: Option<HostUpdate>,
    carry: Option<PartyCarry>,
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
    desktop: Option<Desktop>,
) -> std::io::Result<()> {
    let addr = listener.local_addr()?;
    info!(%addr, "gamenight daemon listening");
    let shared = Arc::new(Mutex::new(Shared::new(library, addr.to_string(), prewarm)));
    if let Some(path) = player_settings_path(music) {
        let mut s = shared.lock().await;
        if let Ok(bytes) = std::fs::read(&path) {
            match serde_json::from_slice::<SavedPlayerSettings>(&bytes) {
                Ok(saved) if saved.version == 1 => s.night.load_player_settings(saved.players),
                _ => warn!(path = %path.display(), "ignoring unreadable player settings"),
            }
        }
        s.player_settings_file = Some(path);
    }
    let exit_with_lobby = desktop.is_some();
    if let Some(desktop) = desktop {
        let mut s = shared.lock().await;
        s.exit_with_lobby = true;
        s.update = desktop.update;
        s.lobby_paths = gamenight_local_web::host_lobby::host_paths();
        if let Some(carry) = desktop.carry {
            info!(players = carry.players.len(), "party restored after update");
            let fx = s.night.restore(carry);
            s.apply_effects(fx, None);
        }
    }
    let watched_lobby = lobby_game.clone();
    if let Some(rx) = install_progress {
        spawn_install_progress_pump(shared.clone(), rx);
    }
    if music {
        spawn_now_playing_watch(shared.clone());
    }
    if let Some(lobby_game) = lobby_game {
        let mut s = shared.lock().await;
        s.night.set_lobby_game(Some(lobby_game.clone()));
        s.lobby_game = Some(lobby_game.clone());
        s.refresh_lobbies();
        // Declare the new contract in the launch spec so even a crash before
        // hello is treated as a plugin failure, not "quit the whole party".
        if s.launch_specs
            .get(&lobby_game)
            .and_then(|spec| spec.env.get("GAMENIGHT_LOBBY_API"))
            .is_some_and(|version| version == "1")
        {
            s.runtime_input = true;
            s.night.preserve_party_on_lobby_disconnect();
            lobby_input::spawn(shared.clone());
        }
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
    let onboarding_file =
        std::env::var_os("GAMENIGHT_ONBOARDING_FILE").map(std::path::PathBuf::from);
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
                if let Some(file) = &onboarding_file {
                    s.refresh_onboarding_error(file);
                }
                s.apply_effects(fx, None);
                continue;
            },
            _ = lifetime_tick.tick() => {
                let mut s = shared.lock().await;
                s.refresh_update_ready();
                s.maybe_update_unattended();
                if s.shutdown_requested {
                    s.kill_all_children();
                    return Ok(());
                }
                s.poll_pending_games();
                s.watch_focus();
                let Some(lobby) = watched_lobby.as_ref() else { continue };
                if !s.exit_with_lobby && !s.runtime_input { continue; }
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
                    if s.runtime_input {
                        // A plugin crash must not kill the game or erase seats.
                        // Bound restarts so a broken package cannot spin forever.
                        if s.lobby_restarts < 3 {
                            s.lobby_restarts += 1;
                            warn!(attempt = s.lobby_restarts, "restarting replacement lobby; party retained");
                            s.running_children.remove(lobby);
                            s.pending_launches.remove(lobby);
                            s.quit_games.remove(lobby);
                            s.launch(lobby);
                        } else if !s.lobby_recovery_opened {
                            s.running_children.remove(lobby);
                            s.pending_launches.remove(lobby);
                            s.lobby_recovery_opened = true;
                            s.dispatch(Command::OverlayOpened,None);
                            if std::env::var_os("GAMENIGHT_WEB").is_some() {
                                if let Err(error)=gamenight_local_web::host_lobby::open_recovery() { warn!(%error,"could not open lobby recovery"); }
                            }
                        }
                        continue;
                    }
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
    stream.set_nodelay(true)?;
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
        Role::Game | Role::Lobby => {
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
            if s.runtime_input && s.lobby_game.as_ref() == Some(&game_id) && role != Role::Lobby {
                send(
                    &tx,
                    &ServerMessage::Error {
                        message: "the selected replacement lobby must use the lobby role".into(),
                    },
                );
                return Err("incorrect lobby role".into());
            }
            if role == Role::Lobby {
                let expected = s
                    .pending_launches
                    .get(&game_id)
                    .map(|p| p.token.as_str())
                    .or(s.lobby_token.as_deref());
                if s.lobby_game.as_ref() != Some(&game_id)
                    || expected.is_none()
                    || token.as_deref() != expected
                {
                    send(
                        &tx,
                        &ServerMessage::Error {
                            message: "lobby requires the selected id and its launch token".into(),
                        },
                    );
                    return Err("unauthorized lobby".into());
                }
                s.lobby_token = token.clone();
            }
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
            s.game_issues.remove(&game_id);
            s.quit_games.remove(&game_id);
            s.games.insert(game_id.clone(), tx.clone());
            send(
                &tx,
                &ServerMessage::Welcome {
                    protocol_version: PROTOCOL_VERSION,
                    godot_sdk: GODOT_SDK_VERSION,
                    party: if role == Role::Lobby {
                        lobby_snapshot(s.snapshot())
                    } else {
                        s.game_snapshot(&game_id)
                    },
                },
            );
            if role == Role::Lobby {
                s.lobby_connections.insert(game_id.clone());
                s.night.preserve_party_on_lobby_disconnect();
                if !s.runtime_input {
                    s.runtime_input = true;
                    lobby_input::spawn(shared.clone());
                }
                Registration::Lobby(game_id)
            } else {
                s.dispatch(
                    Command::GameConnected {
                        game: game_id.clone(),
                    },
                    Some(&tx),
                );
                Registration::Game(game_id)
            }
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
                    godot_sdk: GODOT_SDK_VERSION,
                    party: s.snapshot(),
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
            if matches!(parsed, ClientMessage::RetryLobby) {
                let mut s = shared.lock().await;
                if matches!(
                    registration,
                    Registration::Overlay(_) | Registration::Lobby(_)
                ) && s.runtime_input
                    && s.lobby_recovery_opened
                {
                    if let Some(lobby) = s.lobby_game.clone() {
                        if !s.games.contains_key(&lobby) && !s.pending_launches.contains_key(&lobby)
                        {
                            s.lobby_restarts = 0;
                            s.lobby_recovery_opened = false;
                            s.running_children.remove(&lobby);
                            s.quit_games.remove(&lobby);
                            s.launch(&lobby);
                        }
                    }
                    send(
                        &tx,
                        &ServerMessage::PartyState {
                            party: s.snapshot(),
                        },
                    );
                } else {
                    send(
                        &tx,
                        &ServerMessage::Error {
                            message: "only a local party UI can retry a replacement lobby".into(),
                        },
                    );
                }
                continue;
            }
            if matches!(parsed, ClientMessage::QuitParty)
                && matches!(registration, Registration::Overlay(_))
            {
                let mut s = shared.lock().await;
                if s.lobby_recovery_opened {
                    send(
                        &tx,
                        &ServerMessage::PartyState {
                            party: s.snapshot(),
                        },
                    );
                    s.shutdown_requested = true;
                } else {
                    send(
                        &tx,
                        &ServerMessage::Error {
                            message:
                                "quit is only available through the lobby or its recovery screen"
                                    .into(),
                        },
                    );
                }
                continue;
            }
            if let ClientMessage::SwitchLobby { lobby } = &parsed {
                let mut s = shared.lock().await;
                let result = if matches!(
                    registration,
                    Registration::Lobby(_) | Registration::Overlay(_)
                ) {
                    s.switch_lobby(lobby)
                } else {
                    Err("only the lobby can switch lobbies".into())
                };
                if let Err(message) = result {
                    send(&tx, &ServerMessage::Error { message });
                }
                continue;
            }
            if matches!(parsed, ClientMessage::ApplyUpdate) {
                let mut s = shared.lock().await;
                let result = if matches!(registration, Registration::Lobby(_)) {
                    s.restart_for_update()
                } else {
                    Err("only the lobby can apply an update".into())
                };
                if let Err(message) = result {
                    send(&tx, &ServerMessage::Error { message });
                }
                continue;
            }
            if matches!(
                parsed,
                ClientMessage::LobbyReady | ClientMessage::QuitParty | ClientMessage::RetryLobby
            ) {
                if let Registration::Lobby(game) = &registration {
                    let mut s = shared.lock().await;
                    if matches!(parsed, ClientMessage::QuitParty) {
                        s.shutdown_requested = true;
                    } else {
                        if matches!(parsed, ClientMessage::LobbyReady) {
                            // The new lobby is on screen; the launcher's
                            // update cover may go.
                            if let Some(update) = &s.update {
                                let _ = std::fs::remove_file(&update.splash);
                            }
                        }
                        s.dispatch(Command::GameConnected { game: game.clone() }, Some(&tx));
                    }
                } else {
                    send(
                        &tx,
                        &ServerMessage::Error {
                            message: "only the selected lobby can send this command".into(),
                        },
                    );
                }
                continue;
            }
            if let ClientMessage::Rumble {
                session,
                seat,
                weak,
                strong,
                ms,
            } = parsed
            {
                // The runtime owns the pads, so it also drives their motors.
                // Only the game in front may, and only on its own seats.
                if let Registration::Game(game) = &registration {
                    let target = shared.lock().await.night.rumble_target(game, session, seat);
                    if let Some(controller) = target {
                        lobby_input::rumble(&controller, weak, strong, ms);
                    }
                }
                continue;
            }
            if let ClientMessage::ControllerFrame { .. } = &parsed {
                // The runtime samples physical controllers; no client
                // may inject frames.
                send(
                    &tx,
                    &ServerMessage::Error {
                        message: "only the host publishes controller frames".into(),
                    },
                );
                continue;
            }
            if let ClientMessage::DownloadGrants { grants } = parsed {
                // Only the local web server's cloud bridge holds grants; a
                // game must not unlock paid downloads. Tokens are never logged.
                let s = shared.lock().await;
                if !matches!(registration, Registration::Overlay(_)) {
                    send(
                        &tx,
                        &ServerMessage::Error {
                            message: "only the local web server reports download grants".into(),
                        },
                    );
                } else if let Some(prewarm) = &s.prewarm {
                    debug!(
                        games = ?grants.keys().collect::<Vec<_>>(),
                        "download grants updated"
                    );
                    prewarm.set_grants(grants);
                }
                continue;
            }
            if let ClientMessage::Playtests { playtests } = parsed {
                // Like grants: only the cloud bridge may put private builds
                // on the shelf.
                let mut s = shared.lock().await;
                if !matches!(registration, Registration::Overlay(_)) {
                    send(
                        &tx,
                        &ServerMessage::Error {
                            message: "only the local web server reports playtests".into(),
                        },
                    );
                } else {
                    for playtest in playtests {
                        start_playtest(&mut s, &shared, playtest);
                    }
                }
                continue;
            }
            if matches!(
                parsed,
                ClientMessage::DeclareCompanion { .. }
                    | ClientMessage::CompanionMessage { .. }
                    | ClientMessage::CompanionPresence { .. }
            ) {
                shared.lock().await.companion(parsed, &registration, &tx);
                continue;
            }
            if matches!(
                parsed,
                ClientMessage::DeclareCommands { .. }
                    | ClientMessage::GameCommand { .. }
                    | ClientMessage::CommandResult { .. }
            ) {
                shared.lock().await.game_command(parsed, &registration, &tx);
                continue;
            }
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
                s.companions.remove(game_id);
                s.commands.remove(game_id);
                let mut kind = gamenight_protocol::GameIssueKind::Disconnected;
                if let Some(mut child) = s.running_children.remove(game_id) {
                    if let Ok(Some(status)) = child.try_wait() {
                        kind = if status.success() {
                            gamenight_protocol::GameIssueKind::Closed
                        } else {
                            gamenight_protocol::GameIssueKind::ExitedUnexpectedly
                        };
                        info!(game = %game_id, %status, "game process exited");
                    }
                    if s.exit_with_lobby {
                        let _ = child.start_kill();
                    }
                    tokio::spawn(async move {
                        let _ = child.wait().await;
                    });
                }
                if s.retired.remove(game_id) {
                    // We stopped it ourselves; it may come back when it's wanted.
                    s.dispatch(
                        Command::GameDisconnected {
                            game: game_id.clone(),
                        },
                        None,
                    );
                } else {
                    s.record_game_issue(game_id.clone(), kind);
                }
            }
            Registration::Overlay(id) => {
                info!(overlay = id, "overlay disconnected");
                s.overlays.remove(id);
            }
            Registration::Lobby(game_id) => {
                s.games.remove(game_id);
                s.lobby_connections.remove(game_id);
                s.dispatch(
                    Command::GameDisconnected {
                        game: game_id.clone(),
                    },
                    None,
                );
                // Keep the child and token: a temporary socket failure is
                // recoverable without replacing its process or party.
            }
        }
    }
    drop(tx);
    let _ = writer.await;
    result
}

enum Registration {
    Game(GameId),
    Lobby(GameId),
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
        ClientMessage::ControllerFrame { .. } => {
            return Err("controller frames require lobby routing".into())
        }
        ClientMessage::Rumble { .. } => return Err("rumble requires input routing".into()),
        ClientMessage::Hello { .. } => return Err("already said hello".into()),
        ClientMessage::DeclareCompanion { .. }
        | ClientMessage::CompanionMessage { .. }
        | ClientMessage::CompanionPresence { .. } => {
            return Err("phone screens require dedicated routing".into())
        }
        ClientMessage::DeclareCommands { .. }
        | ClientMessage::GameCommand { .. }
        | ClientMessage::CommandResult { .. } => {
            return Err("game commands require dedicated routing".into())
        }
        ClientMessage::LobbyReady
        | ClientMessage::QuitParty
        | ClientMessage::RetryLobby
        | ClientMessage::ApplyUpdate
        | ClientMessage::SwitchLobby { .. } => {
            return Err("lobby lifecycle requires dedicated routing".into())
        }
        ClientMessage::DownloadGrants { .. } | ClientMessage::Playtests { .. } => {
            return Err("download grants require dedicated routing".into())
        }
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
        ClientMessage::Performance { session, sample } => match registration {
            Registration::Game(game) => Command::Performance {
                game: game.clone(),
                session,
                sample,
            },
            _ => return Err("only games report performance".into()),
        },
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
            Registration::Overlay(_) | Registration::Lobby(_) => {
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
            Registration::Overlay(_) | Registration::Lobby(_) => {
                return Err("only games declare settings".into())
            }
        },
        // A game's own menu may change its own settings, so the party's apps
        // and LLMs see the same values. The game id comes from the
        // connection, never the message: a game cannot touch another's.
        ClientMessage::SetSetting { key, value, .. } if is_game => match registration {
            Registration::Game(game) => Command::SetSetting {
                game: Some(game.clone()),
                key,
                value,
            },
            _ => return Err("only games change their own settings".into()),
        },
        ClientMessage::SetPlayerSetting {
            player_id,
            key,
            value,
            ..
        } if is_game => match registration {
            Registration::Game(game) => Command::SetPlayerSetting {
                game: Some(game.clone()),
                player_id,
                key,
                value,
            },
            _ => return Err("only games change their own settings".into()),
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
        ClientMessage::SetPhones { players } => Command::SetPhones { players },
        ClientMessage::JoinPhonePlayer {
            name,
            color,
            avatar,
        } => Command::JoinPhonePlayer {
            name,
            color,
            avatar,
        },
        ClientMessage::RenamePlayer { player_id, name } => {
            Command::RenamePlayer { player_id, name }
        }
        ClientMessage::SetPlayerSkinColor {
            player_id,
            skin_color,
        } => Command::SetPlayerSkinColor {
            player_id,
            skin_color,
        },
        ClientMessage::SetPlayerColor { player_id, color } => {
            Command::SetPlayerColor { player_id, color }
        }
        ClientMessage::SetPlayerAvatar { player_id, avatar } => {
            Command::SetPlayerAvatar { player_id, avatar }
        }
        ClientMessage::SetPlayerProfile { player_id, profile } => {
            Command::SetPlayerProfile { player_id, profile }
        }
        ClientMessage::AssignSeat { seat, occupant } => Command::AssignSeat { seat, occupant },
        ClientMessage::SwapSeats { a, b } => Command::SwapSeats { a, b },
        ClientMessage::SetCouchPosition {
            player_id,
            position,
        } => Command::SetCouchPosition {
            player_id,
            position,
        },
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
        ClientMessage::RemovePlaylistEntry { expected, index } => {
            Command::RemovePlaylistEntry { expected, index }
        }
        ClientMessage::Next => Command::Next,
        ClientMessage::PlayNext { game } => Command::PlayNext { game },
        ClientMessage::QueueNext { game } => Command::QueueNext { game },
        ClientMessage::QueueGame { game, first } => Command::QueueGame { game, first },
        ClientMessage::Pause => Command::Pause,
        ClientMessage::Resume => Command::Resume,
        ClientMessage::OpenOverlay => Command::OverlayOpened,
        ClientMessage::CloseOverlay => Command::OverlayClosed,
        ClientMessage::Vote { player_id, option } => Command::Vote { player_id, option },
        ClientMessage::ControlSettings {
            game,
            session,
            expected_revision,
            player_id,
            action,
            values,
        } => Command::ControlSettings {
            game,
            session,
            expected_revision,
            player_id,
            action,
            values,
        },
        ClientMessage::SetSetting { game, key, value } => Command::SetSetting { game, key, value },
        ClientMessage::SetPlayerSetting {
            game,
            player_id,
            key,
            value,
        } => Command::SetPlayerSetting {
            game,
            player_id,
            key,
            value,
        },
        ClientMessage::MediaControl { action } => Command::MediaControl { action },
    };
    Ok(Some(command))
}

#[cfg(test)]
mod replacement_lobby_tests {
    use super::*;
    #[test]
    fn onboarding_error_is_visible_without_a_phantom_game_and_clears() {
        let file =
            std::env::temp_dir().join(format!("onboarding-error-{}.json", uuid::Uuid::new_v4()));
        let mut s = Shared::new(vec![], "127.0.0.1:0".into(), None);
        std::fs::write(&file, r#"{"game":"hexstead","complete":false,"error":"Hexstead is not available on this computer."}"#).unwrap();
        s.refresh_onboarding_error(&file);
        assert!(s
            .snapshot()
            .onboarding_error
            .unwrap()
            .contains("not available"));
        assert!(s.snapshot().library.is_empty());
        assert!(s.snapshot().playlist.entries.is_empty());
        s.dispatch(Command::Next, None);
        s.refresh_onboarding_error(&file);
        assert!(
            s.snapshot().onboarding_error.is_none(),
            "choosing another game dismisses the banner"
        );
        std::fs::write(&file, r#"{"game":"hexstead","complete":true}"#).unwrap();
        s.refresh_onboarding_error(&file);
        assert!(s.snapshot().onboarding_error.is_none());
        assert!(s.dismissed_onboarding_error.is_none());
        std::fs::remove_file(file).unwrap();
    }
    type Ws = tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<TcpStream>>;

    fn test_game(launch: serde_json::Value) -> GameMeta {
        serde_json::from_value(serde_json::json!({"id":"test", "title":"Test", "launch":launch}))
            .unwrap()
    }

    #[tokio::test]
    async fn exited_before_hello_is_reported_once_and_only_retries_on_request() {
        #[cfg(windows)]
        let launch = serde_json::json!({"command":"cmd.exe","args":["/C","exit","7"]});
        #[cfg(not(windows))]
        let launch = serde_json::json!({"command":"/bin/sh","args":["-c","exit 7"]});
        let mut s = Shared::new(vec![test_game(launch)], "127.0.0.1:0".into(), None);
        s.night.set_lobby_game(Some(GameId::new("lobby")));
        let (tx, mut rx) = mpsc::unbounded_channel();
        s.overlays.insert(0, tx);
        let game = GameId::new("test");
        s.launch(&game);
        tokio::time::timeout(std::time::Duration::from_secs(3), async {
            while s.game_issues.is_empty() {
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
                s.poll_pending_games();
            }
        })
        .await
        .unwrap();
        assert_eq!(
            s.snapshot().game_issues[0].kind,
            gamenight_protocol::GameIssueKind::FailedToStart
        );
        assert!(s.pending_launches.is_empty());
        let update: ServerMessage = serde_json::from_str(&rx.try_recv().unwrap()).unwrap();
        assert!(
            matches!(update, ServerMessage::PartyState { party } if party.game_issues.len() == 1 && party.warm_session.is_none())
        );
        s.poll_pending_games();
        assert!(rx.try_recv().is_err(), "no repeated failure broadcasts");
        s.launch(&game);
        assert!(s.pending_launches.is_empty(), "no automatic restart loop");
        s.dispatch(Command::QueueNext { game: game.clone() }, None);
        assert!(s.game_issues.is_empty());
        assert!(s.pending_launches.contains_key(&game));
        s.kill_all_children();
    }

    #[cfg(not(windows))]
    #[tokio::test]
    async fn changing_the_next_game_stops_the_one_it_replaced() {
        let library = ["one", "two", "three"]
            .map(|id| {
                serde_json::from_value(serde_json::json!({"id":id,"title":id,
                    "launch":{"command":"sleep","args":["30"]}}))
                .unwrap()
            })
            .to_vec();
        let mut s = Shared::new(library, "127.0.0.1:0".into(), None);
        s.night.set_lobby_game(Some(GameId::new("lobby")));
        for id in ["one", "two", "three"] {
            s.dispatch(
                Command::QueueGame {
                    game: GameId::new(id),
                    first: false,
                },
                None,
            );
        }
        let loaded = |s: &Shared| {
            let mut games: Vec<String> = s
                .pending_launches
                .keys()
                .chain(s.running_children.keys())
                .map(|g| g.0.clone())
                .collect();
            games.sort();
            games
        };
        assert_eq!(loaded(&s), ["one"]);
        for id in ["two", "three", "two"] {
            s.dispatch(
                Command::QueueNext {
                    game: GameId::new(id),
                },
                None,
            );
            assert_eq!(loaded(&s), [id], "only the next game stays loaded");
        }
        assert!(
            s.game_issues.is_empty(),
            "a stopped preload is not a failure"
        );
        s.kill_all_children();
    }

    #[test]
    fn retry_next_preserves_issues_for_other_closed_games() {
        let mut s = Shared::new(
            vec![test_game(serde_json::Value::Null)],
            "127.0.0.1:0".into(),
            None,
        );
        s.night.set_lobby_game(Some(GameId::new("lobby")));
        for id in ["test", "other"] {
            s.record_game_issue(GameId::new(id), gamenight_protocol::GameIssueKind::Closed);
        }
        s.dispatch(Command::Next, None);
        assert!(!s.game_issues.contains_key(&GameId::new("test")));
        assert!(s.game_issues.contains_key(&GameId::new("other")));
        assert!(s.quit_games.contains(&GameId::new("other")));
    }

    #[tokio::test]
    async fn spawn_error_and_connection_timeout_are_visible() {
        let mut s = Shared::new(
            vec![test_game(
                serde_json::json!({"command":"missing-gamenight-test-executable"}),
            )],
            "127.0.0.1:0".into(),
            None,
        );
        s.night.set_lobby_game(Some(GameId::new("lobby")));
        let game = GameId::new("test");
        s.launch(&game);
        assert_eq!(
            s.snapshot().game_issues[0].kind,
            gamenight_protocol::GameIssueKind::FailedToStart
        );
        #[cfg(windows)]
        let child = tokio::process::Command::new("cmd.exe")
            .args(["/C", "ping -n 30 127.0.0.1 > nul"])
            .spawn()
            .unwrap();
        #[cfg(not(windows))]
        let child = tokio::process::Command::new("sleep")
            .arg("30")
            .spawn()
            .unwrap();
        s.pending_launches.insert(
            game.clone(),
            PendingLaunch {
                token: "test".into(),
                child,
                spawned_at: std::time::Instant::now()
                    - LAUNCH_HELLO_TIMEOUT
                    - std::time::Duration::from_secs(1),
            },
        );
        s.poll_pending_games();
        assert_eq!(
            s.snapshot().game_issues[0].kind,
            gamenight_protocol::GameIssueKind::StartupTimeout
        );
        assert!(s.pending_launches.is_empty());
    }

    #[tokio::test]
    async fn closed_preload_notifies_peers_and_reconnection_prepares_fresh_session() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap().to_string();
        let mut initial = Shared::new(vec![test_game(serde_json::Value::Null)], addr.clone(), None);
        initial.night.set_lobby_game(Some(GameId::new("lobby")));
        let state = Arc::new(Mutex::new(initial));
        let server_state = state.clone();
        let server = tokio::spawn(async move {
            loop {
                let (stream, _) = listener.accept().await.unwrap();
                let state = server_state.clone();
                tokio::spawn(async move {
                    let _ = handle_connection(stream, state).await;
                });
            }
        });
        let mut game = connect(&addr, Role::Game, "test", "").await;
        assert!(matches!(
            receive(&mut game).await,
            ServerMessage::Welcome { .. }
        ));
        let session = match receive(&mut game).await {
            ServerMessage::Prepare { session, .. } => session,
            other => panic!("{other:?}"),
        };
        game.send(Message::Text(ClientMessage::Ready { session }.to_json()))
            .await
            .unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            loop {
                if state
                    .lock()
                    .await
                    .snapshot()
                    .warm_session
                    .as_ref()
                    .is_some_and(|s| s.phase == gamenight_protocol::SessionPhase::Ready)
                {
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        let mut overlay = connect(&addr, Role::Overlay, "", "").await;
        receive(&mut overlay).await;
        game.close(None).await.unwrap();
        loop {
            if let ServerMessage::PartyState { party } = receive(&mut overlay).await {
                if !party.game_issues.is_empty() {
                    assert!(party.warm_session.is_none());
                    assert!(!party.connected_games.contains(&GameId::new("test")));
                    break;
                }
            }
        }
        let mut new_overlay = connect(&addr, Role::Overlay, "", "").await;
        assert!(
            matches!(receive(&mut new_overlay).await, ServerMessage::Welcome { party, .. } if party.game_issues.len() == 1)
        );
        let mut restarted = connect(&addr, Role::Game, "test", "").await;
        assert!(
            matches!(receive(&mut restarted).await, ServerMessage::Welcome { party, .. } if party.game_issues.is_empty())
        );
        assert!(
            matches!(receive(&mut restarted).await, ServerMessage::Prepare { session: fresh, .. } if fresh != session)
        );
        restarted.close(None).await.unwrap();
        overlay.close(None).await.unwrap();
        new_overlay.close(None).await.unwrap();
        server.abort();
    }

    /// A signed-in player's own setting is written to disk and reaches the
    /// game; a guest's is not written.
    #[test]
    fn game_commands_go_to_the_game_and_answers_to_overlays() {
        let mut s = Shared::new(Vec::new(), "127.0.0.1:1".into(), None);
        let game = GameId::new("mineclonia");
        let (game_tx, mut game_rx) = mpsc::unbounded_channel();
        let (web_tx, mut web_rx) = mpsc::unbounded_channel();
        s.games.insert(game.clone(), game_tx.clone());
        s.overlays.insert(0, web_tx.clone());
        let next = |rx: &mut mpsc::UnboundedReceiver<String>| -> ServerMessage {
            serde_json::from_str(&rx.try_recv().unwrap()).unwrap()
        };
        s.dispatch(
            Command::JoinParty {
                name: "Ada".into(),
                seat: None,
                color: None,
                avatar: None,
                library: vec![],
            },
            None,
        );
        while web_rx.try_recv().is_ok() {}
        let ada = s.night.snapshot().players[0].id;
        let ask = |text: &str| ClientMessage::GameCommand {
            game: game.clone(),
            player_id: ada,
            id: "r1".into(),
            text: text.into(),
        };
        // Nothing declared yet: the request is refused, not forwarded.
        s.game_command(ask("geef me 10 brood"), &Registration::Overlay(0), &web_tx);
        assert!(matches!(next(&mut web_rx), ServerMessage::Error { .. }));
        s.game_command(
            ClientMessage::DeclareCommands {
                description: "Ask for items".into(),
                examples: vec!["geef me 10 End Crystal".into()],
            },
            &Registration::Game(game.clone()),
            &game_tx,
        );
        let ServerMessage::PartyState { party } = next(&mut web_rx) else {
            panic!("expected a party update");
        };
        assert_eq!(party.commands[0].examples[0], "geef me 10 End Crystal");
        s.game_command(ask("geef me 10 brood"), &Registration::Overlay(0), &web_tx);
        assert!(matches!(
            next(&mut game_rx),
            ServerMessage::GameCommand { player_id, id, text, .. }
                if player_id == ada && id == "r1" && text == "geef me 10 brood"
        ));
        s.game_command(
            ClientMessage::CommandResult {
                id: "r1".into(),
                ok: true,
                message: "Alsjeblieft: 10× Bread.".into(),
            },
            &Registration::Game(game.clone()),
            &game_tx,
        );
        assert!(matches!(
            next(&mut web_rx),
            ServerMessage::CommandResult { game: g, id, ok: true, .. } if g == game && id == "r1"
        ));
        // A game cannot ask another game, and overlays cannot answer.
        s.game_command(ask("geef"), &Registration::Game(game.clone()), &game_tx);
        assert!(matches!(next(&mut game_rx), ServerMessage::Error { .. }));
        s.game_command(
            ClientMessage::CommandResult {
                id: "r1".into(),
                ok: true,
                message: String::new(),
            },
            &Registration::Overlay(0),
            &web_tx,
        );
        assert!(matches!(next(&mut web_rx), ServerMessage::Error { .. }));
    }

    #[test]
    fn player_settings_are_saved_for_profiles_and_sent_to_the_game() {
        let dir = std::env::temp_dir().join(format!("gamenight-ps-{}", uuid::Uuid::new_v4()));
        let path = dir.join("player-settings.json");
        let mut s = Shared::new(
            vec![test_game(serde_json::Value::Null)],
            "127.0.0.1:0".into(),
            None,
        );
        s.player_settings_file = Some(path.clone());
        let (tx, mut rx) = mpsc::unbounded_channel();
        let game = GameId::new("test");
        s.games.insert(game.clone(), tx);
        s.dispatch(
            Command::JoinParty {
                name: "Ada".into(),
                seat: None,
                color: None,
                avatar: None,
                library: vec![],
            },
            None,
        );
        let ada = s.night.snapshot().players[0].id;
        s.dispatch(
            Command::DeclareSettings {
                game: game.clone(),
                settings: vec![serde_json::from_value(serde_json::json!({
                    "key": "character", "label": "Character", "kind": "choice",
                    "default": "frog", "options": ["frog", "cat"], "scope": "player"
                }))
                .unwrap()],
            },
            None,
        );
        let set = |s: &mut Shared| {
            s.dispatch(
                Command::SetPlayerSetting {
                    game: Some(GameId::new("test")),
                    player_id: ada,
                    key: "character".into(),
                    value: gamenight_protocol::SettingValue::Choice("cat".into()),
                },
                None,
            )
        };
        set(&mut s);
        assert!(!path.exists(), "a guest's choice stays in memory");
        s.dispatch(
            Command::SetPlayerProfile {
                player_id: ada,
                profile: Some("local:ada".into()),
            },
            None,
        );
        let saved: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(saved["players"]["local:ada"]["test"]["character"], "cat");
        let mut got = None;
        while let Ok(message) = rx.try_recv() {
            if let Ok(ServerMessage::PlayerSettings {
                player_id, values, ..
            }) = serde_json::from_str::<ServerMessage>(&message)
            {
                if player_id == ada {
                    got = values.get("character").cloned();
                }
            }
        }
        assert_eq!(
            got,
            Some(gamenight_protocol::SettingValue::Choice("cat".into()))
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    /// Games get a per-game profile key for a player with a profile; the
    /// overlays and phones never see it.
    #[tokio::test]
    async fn games_receive_a_profile_key_overlays_do_not() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap().to_string();
        let state = Arc::new(Mutex::new(Shared::new(
            vec![test_game(serde_json::Value::Null)],
            addr.clone(),
            None,
        )));
        let server_state = state.clone();
        let server = tokio::spawn(async move {
            loop {
                let (stream, _) = listener.accept().await.unwrap();
                let state = server_state.clone();
                tokio::spawn(async move {
                    let _ = handle_connection(stream, state).await;
                });
            }
        });
        let mut overlay = connect(&addr, Role::Overlay, "", "").await;
        receive(&mut overlay).await;
        overlay
            .send(Message::Text(
                ClientMessage::JoinParty {
                    name: "Ada".into(),
                    seat: None,
                    color: None,
                    avatar: None,
                    library: vec![],
                }
                .to_json(),
            ))
            .await
            .unwrap();
        let player_id = loop {
            if let ServerMessage::PartyState { party } = receive(&mut overlay).await {
                if let Some(player) = party.players.first() {
                    break player.id;
                }
            }
        };
        overlay
            .send(Message::Text(
                ClientMessage::SetPlayerProfile {
                    player_id,
                    profile: Some("account:ada".into()),
                }
                .to_json(),
            ))
            .await
            .unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            while state
                .lock()
                .await
                .night
                .profile_key(&GameId::new("test"), player_id)
                .is_none()
            {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        let expected = gamenight_protocol::profile_key(&GameId::new("test"), "account:ada");
        let mut game = connect(&addr, Role::Game, "test", "").await;
        match receive(&mut game).await {
            ServerMessage::Welcome { party, .. } => {
                assert_eq!(
                    party.players[0].profile_key.as_deref(),
                    Some(expected.as_str())
                )
            }
            other => panic!("{other:?}"),
        }
        match receive(&mut game).await {
            ServerMessage::Prepare { players, .. } => {
                assert_eq!(players[0].profile_key.as_deref(), Some(expected.as_str()))
            }
            other => panic!("{other:?}"),
        }
        assert!(state.lock().await.snapshot().players[0]
            .profile_key
            .is_none());
        game.close(None).await.unwrap();
        overlay.close(None).await.unwrap();
        server.abort();
    }

    #[test]
    fn lobby_snapshot_keeps_art_but_omits_launch_internals() {
        let game = serde_json::from_value(serde_json::json!({
            "id": "game", "title": "Game", "cover": "data:image/png;base64,test",
            "launch": {"command": "private/path", "env": {"PRIVATE_VALUE": "test"}}
        }))
        .unwrap();
        let state = Shared::new(vec![game], "127.0.0.1:0".into(), None);
        let party = lobby_snapshot(state.night.snapshot());
        assert!(party.library[0].cover.is_some());
        assert!(party.library[0].launch.is_none());
    }

    async fn receive(ws: &mut Ws) -> ServerMessage {
        let frame = tokio::time::timeout(std::time::Duration::from_secs(2), ws.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        serde_json::from_str(frame.to_text().unwrap()).unwrap()
    }

    async fn connect(addr: &str, role: Role, id: &str, token: &str) -> Ws {
        let (mut ws, _) = tokio_tungstenite::connect_async(format!("ws://{addr}"))
            .await
            .unwrap();
        ws.send(Message::Text(
            ClientMessage::Hello {
                role,
                game: Some(GameId::new(id)),
                token: Some(token.into()),
            }
            .to_json(),
        ))
        .await
        .unwrap();
        ws
    }

    #[test]
    fn phone_screens_may_be_a_page_a_native_app_or_both() {
        use gamenight_protocol::{CompanionApp, CompanionScreen};
        let root = std::env::temp_dir().display().to_string();
        let app = |download: &str| CompanionApp {
            name: "The Voice and the Will".into(),
            android: Some("io.ontola.godgame".into()),
            download: Some(download.into()),
        };
        let screen =
            |root: Option<&str>, entry: Option<&str>, app: Option<CompanionApp>| CompanionScreen {
                game: GameId::new("god"),
                root: root.map(Into::into),
                entry: entry.map(Into::into),
                app,
            };
        assert!(valid_companion(&screen(
            None,
            None,
            Some(app("https://example.org/god.apk"))
        ))
        .is_ok());
        assert!(valid_companion(&screen(Some(&root), None, Some(app("god.apk")))).is_ok());
        assert!(valid_companion(&screen(Some(&root), Some("index.html"), None)).is_ok());
        assert!(
            valid_companion(&screen(None, None, Some(app("god.apk")))).is_err(),
            "a file needs a root"
        );
        assert!(valid_companion(&screen(Some(&root), None, Some(app("../god.apk")))).is_err());
        assert!(
            valid_companion(&screen(None, None, Some(app("http://example.org/god.apk")))).is_err()
        );
        assert!(
            valid_companion(&screen(Some(&root), None, None)).is_err(),
            "nothing to show"
        );
        assert!(valid_companion(&screen(None, Some("index.html"), None)).is_err());
    }

    #[test]
    fn phone_screens_route_between_games_and_the_local_web_server() {
        let mut shared = Shared::new(Vec::new(), "127.0.0.1:1".into(), None);
        let game = GameId::new("hexstead");
        let (game_tx, mut game_rx) = mpsc::unbounded_channel();
        let (web_tx, mut web_rx) = mpsc::unbounded_channel();
        shared.games.insert(game.clone(), game_tx.clone());
        shared.overlays.insert(0, web_tx.clone());
        let as_game = Registration::Game(game.clone());
        let as_web = Registration::Overlay(0);
        // Absolute on every platform ("/games" is relative on Windows).
        let root = std::env::temp_dir().join("hexstead").display().to_string();
        let next = |rx: &mut mpsc::UnboundedReceiver<String>| -> ServerMessage {
            serde_json::from_str(&rx.try_recv().unwrap()).unwrap()
        };

        shared.companion(
            ClientMessage::DeclareCompanion {
                root: Some("relative/dir".into()),
                entry: Some("phone.html".into()),
                app: None,
            },
            &as_game,
            &game_tx,
        );
        assert!(matches!(next(&mut game_rx), ServerMessage::Error { .. }));
        shared.companion(
            ClientMessage::DeclareCompanion {
                root: Some(root.clone()),
                entry: Some("phone/index.html".into()),
                app: None,
            },
            &as_game,
            &game_tx,
        );
        let ServerMessage::PartyState { party } = next(&mut web_rx) else {
            panic!("expected a party update");
        };
        assert_eq!(party.companions[0].root.as_deref(), Some(root.as_str()));
        assert!(lobby_snapshot(party.clone()).companions[0].root.is_none());
        assert!(game_welcome_snapshot(party).companions.is_empty());

        let player = gamenight_protocol::PlayerId::new();
        shared.companion(
            ClientMessage::CompanionPresence {
                game: game.clone(),
                player_id: player,
                connected: true,
            },
            &as_web,
            &web_tx,
        );
        assert!(matches!(
            next(&mut game_rx),
            ServerMessage::CompanionPresence { player_id, connected: true } if player_id == player
        ));
        shared.companion(
            ClientMessage::CompanionMessage {
                game: Some(game.clone()),
                player_id: Some(player),
                data: serde_json::json!({"roll": true}),
            },
            &as_web,
            &web_tx,
        );
        assert!(matches!(
            next(&mut game_rx),
            ServerMessage::CompanionMessage { player_id: Some(p), data, .. } if p == player && data["roll"] == true
        ));
        shared.companion(
            ClientMessage::CompanionMessage {
                game: None,
                player_id: Some(player),
                data: serde_json::json!({"hand": ["wool"]}),
            },
            &as_game,
            &game_tx,
        );
        assert!(matches!(
            next(&mut web_rx),
            ServerMessage::CompanionMessage { game: g, player_id: Some(p), .. } if g == game && p == player
        ));
        // Games cannot impersonate a phone, and phones need an address.
        shared.companion(
            ClientMessage::CompanionPresence {
                game: game.clone(),
                player_id: player,
                connected: false,
            },
            &as_game,
            &game_tx,
        );
        assert!(matches!(next(&mut game_rx), ServerMessage::Error { .. }));
        shared.companion(
            ClientMessage::CompanionMessage {
                game: None,
                player_id: None,
                data: serde_json::Value::Null,
            },
            &as_web,
            &web_tx,
        );
        assert!(matches!(next(&mut web_rx), ServerMessage::Error { .. }));
    }

    #[test]
    fn host_music_updates_reach_games_without_catalog_art_or_repeated_polls() {
        let game: GameMeta = serde_json::from_value(serde_json::json!({
            "id":"music-test", "title":"Test", "cover":"embedded-cover", "screenshot":"embedded-shot"
        })).unwrap();
        let mut shared = Shared::new(vec![game], "127.0.0.1:1".into(), None);
        let (tx, mut rx) = mpsc::unbounded_channel();
        shared.games.insert(GameId::new("music-test"), tx);
        let mut track = gamenight_protocol::NowPlaying {
            title: "Test track".into(),
            artist: String::new(),
            source: "Test player".into(),
            playing: true,
        };
        for value in [
            Some(track.clone()),
            {
                track.playing = false;
                Some(track.clone())
            },
            None,
        ] {
            shared.dispatch(
                Command::NowPlaying {
                    track: value.clone(),
                },
                None,
            );
            let message: ServerMessage = serde_json::from_str(&rx.try_recv().unwrap()).unwrap();
            let ServerMessage::PartyState { party } = message else {
                panic!("expected music snapshot")
            };
            assert_eq!(party.now_playing, value);
            assert!(party
                .library
                .iter()
                .all(|g| g.cover.is_none() && g.screenshot.is_none()));
            shared.dispatch(Command::NowPlaying { track: value }, None);
            assert!(rx.try_recv().is_err(), "unchanged poll should send nothing");
        }
    }

    #[tokio::test]
    async fn replacement_lobby_is_selected_authenticated_and_cannot_publish_input_or_game_lifecycle(
    ) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap().to_string();
        let mut state = Shared::new(Vec::new(), addr.clone(), None);
        state.lobby_game = Some(GameId::new("test-room"));
        state.night.set_lobby_game(state.lobby_game.clone());
        state.lobby_token = Some("test-launch-token".into());
        state.runtime_input = true; // deterministic test: no hardware sampling
        let shared = Arc::new(Mutex::new(state));
        let task = tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                let shared = shared.clone();
                tokio::spawn(async move {
                    let _ = handle_connection(stream, shared).await;
                });
            }
        });
        for (role, id, token) in [
            (Role::Lobby, "other-room", "test-launch-token"),
            (Role::Lobby, "test-room", "wrong-token"),
            (Role::Game, "test-room", "test-launch-token"),
        ] {
            let mut ws = connect(&addr, role, id, token).await;
            assert!(matches!(
                receive(&mut ws).await,
                ServerMessage::Error { .. }
            ));
        }
        let mut ws = connect(&addr, Role::Lobby, "test-room", "test-launch-token").await;
        assert!(matches!(
            receive(&mut ws).await,
            ServerMessage::Welcome { .. }
        ));
        for message in [
            ClientMessage::ControllerFrame {
                controllers: Vec::new(),
            },
            ClientMessage::Ready {
                session: SessionId::default(),
            },
        ] {
            ws.send(Message::Text(message.to_json())).await.unwrap();
            assert!(matches!(
                receive(&mut ws).await,
                ServerMessage::Error { .. }
            ));
        }
        ws.send(Message::Text(ClientMessage::LobbyReady.to_json()))
            .await
            .unwrap();
        let mut focus = false;
        let mut snapshot = false;
        for _ in 0..2 {
            match receive(&mut ws).await {
                ServerMessage::LobbyFocus { active } => focus = active,
                ServerMessage::PartyState { .. } => snapshot = true,
                other => panic!("unexpected {other:?}"),
            }
        }
        assert!(focus && snapshot);
        ws.close(None).await.unwrap();
        task.abort();
    }
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
                Some(Desktop {
                    update: None,
                    carry: None,
                }),
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
            run_inner(listener, Vec::new(), None, None, None, false, None)
        )
        .await
        .is_err());
    }

    #[tokio::test]
    async fn replacement_lobby_crashing_before_hello_does_not_end_the_runtime() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        #[cfg(windows)]
        let command = serde_json::json!({"command":"cmd.exe", "args":["/C", "exit", "0"], "env":{"GAMENIGHT_LOBBY_API":"1"}});
        #[cfg(not(windows))]
        let command = serde_json::json!({"command":"/bin/sh", "args":["-c", "exit 0"], "env":{"GAMENIGHT_LOBBY_API":"1"}});
        let lobby = serde_json::from_value(
            serde_json::json!({"id":"replacement", "title":"Replacement", "launch":command}),
        )
        .unwrap();
        assert!(tokio::time::timeout(
            std::time::Duration::from_millis(1500),
            run_inner(
                listener,
                vec![lobby],
                Some(GameId::new("replacement")),
                None,
                None,
                false,
                Some(Desktop {
                    update: None,
                    carry: None
                })
            )
        )
        .await
        .is_err());
    }
}

#[cfg(test)]
mod local_artwork_tests {
    #[test]
    fn local_shelf_entries_keep_their_catalogue_art() {
        let mut library = super::demo_library();
        library[0].cover = Some("own.png".into());
        let shipped: gamenight_catalog::CatalogEntry =
            serde_json::from_str(include_str!("../../../catalog/games/demo-game.json")).unwrap();
        let mut catalog = shipped.clone();
        catalog.cover = Some("https://example.com/cover.png".into());
        catalog.icon = Some("https://example.com/icon.png".into());
        let mut other = shipped;
        other.id = "other".into();
        other.screenshot = Some("https://example.com/s.png".into());
        super::add_catalog_art(&mut library, &[other, catalog]);
        assert_eq!(library[0].cover.as_deref(), Some("own.png"), "own art wins");
        assert_eq!(
            library[0].icon.as_deref(),
            Some("https://example.com/icon.png")
        );
        assert!(library[0].screenshot.is_none(), "only the same game's art");
    }

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
        std::fs::write(root.join("shelf.json"), r##"[{"id":"one","title":"One","cover":"icon.png","icon":"icon.png","screenshot":"icon.png","color":"#44CCAA"},{"id":"two","title":"Two","cover":"missing.png"},{"id":"three","title":"Three","cover":"../icon.png"}]"##).unwrap();
        let games = super::load_library(root.join("shelf.json").to_str().unwrap()).unwrap();
        assert_eq!(
            gamenight_protocol::artwork::decode_png_data_uri(games[0].cover.as_ref().unwrap()),
            Some(png)
        );
        assert_eq!(games[0].icon, games[0].cover);
        assert_eq!(games[0].screenshot, games[0].cover);
        assert_eq!(games[0].color.as_deref(), Some("#44CCAA"));
        assert!(games[1].cover.is_none());
        assert!(games[2].cover.is_none());
        std::fs::remove_dir_all(root).unwrap();
    }
}

#[cfg(test)]
mod welcome_artwork_tests {
    use super::*;

    #[test]
    fn game_welcome_omits_large_catalog_art_but_preserves_metadata() {
        let mut night = GameNight::default();
        let art = "x".repeat(400_000);
        let game: GameMeta = serde_json::from_value(serde_json::json!({
            "id": "test", "title": "Test", "cover": art,
            "icon": art, "screenshot": art, "min_players": 2
        }))
        .unwrap();
        night.set_library(vec![game]);
        let original = night.snapshot();
        assert!(serde_json::to_vec(&original).unwrap().len() > 1024 * 1024);
        let compact = game_welcome_snapshot(original.clone());
        assert!(serde_json::to_vec(&compact).unwrap().len() < 1024 * 1024);
        assert_eq!(compact.library[0].title, original.library[0].title);
        assert_eq!(
            compact.library[0].min_players,
            original.library[0].min_players
        );
        assert!(compact.library[0].cover.is_none());
        assert!(compact.library[0].icon.is_none());
        assert!(compact.library[0].screenshot.is_none());
        assert!(original.library[0].cover.is_some());
    }
}

#[cfg(test)]
mod update_restart_tests {
    use super::*;

    fn host_update() -> HostUpdate {
        let dir = std::env::temp_dir().join(format!("gamenight-update-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        HostUpdate {
            ready: dir.join("update-ready.json"),
            resume: dir.join("resume.json"),
            splash: dir.join("update-splash.flag"),
        }
    }

    fn join(s: &mut Shared, name: &str, controller: &str) -> gamenight_protocol::PlayerId {
        s.dispatch(
            Command::JoinParty {
                name: name.into(),
                seat: None,
                color: Some("#ff4f8b".into()),
                avatar: None,
                library: Vec::new(),
            },
            None,
        );
        let id = s
            .night
            .snapshot()
            .players
            .iter()
            .find(|p| p.name == name)
            .unwrap()
            .id;
        s.dispatch(
            Command::BindController {
                player_id: id,
                controller: controller.into(),
            },
            None,
        );
        id
    }

    #[test]
    fn switching_lobby_saves_the_choice_and_restarts_with_the_party() {
        let update = host_update();
        let dir = update.resume.parent().unwrap().to_path_buf();
        let (config, registrations, bundled) = (
            dir.join("selected-lobby.json"),
            dir.join("local-games.json"),
            dir.join("bundled-lobbies.json"),
        );
        let exe = std::env::current_exe().unwrap();
        std::fs::write(
            &bundled,
            serde_json::json!([{"id":"game-room","title":"Game Room",
            "launch":{"command":exe,"env":{"GAMENIGHT_LOBBY_API":"1"}}}])
            .to_string(),
        )
        .unwrap();
        std::fs::write(
            &registrations,
            serde_json::json!([{"id":"living-room","title":"Living Room",
            "launch":{"command":exe,"env":{"GAMENIGHT_LOBBY_API":"1"}}}])
            .to_string(),
        )
        .unwrap();
        let mut s = Shared::new(vec![], "127.0.0.1:0".into(), None);
        s.lobby_game = Some(GameId::new("game-room"));
        s.lobby_paths = Some((config.clone(), registrations, Some(bundled)));
        s.refresh_lobbies();
        let lobbies = s.snapshot().lobbies;
        assert_eq!(
            lobbies
                .iter()
                .map(|l| (l.id.0.as_str(), l.current))
                .collect::<Vec<_>>(),
            [("game-room", true), ("living-room", false)]
        );
        assert!(s.switch_lobby(&GameId::new("missing")).is_err());
        s.switch_lobby(&GameId::new("game-room")).unwrap();
        assert!(!s.shutdown_requested, "the running lobby needs no restart");
        assert!(s.switch_lobby(&GameId::new("lobby")).is_err());
        let error = s.switch_lobby(&GameId::new("living-room")).unwrap_err();
        assert!(error.contains("next time"), "{error}");
        s.update = Some(update.clone());
        join(&mut s, "Ada", "xinput:0");
        s.switch_lobby(&GameId::new("living-room")).unwrap();
        assert!(s.shutdown_requested);
        assert_eq!(
            std::fs::read_to_string(&config).unwrap(),
            r#"{"id":"living-room"}"#
        );
        let resume = Resume::take(&update.resume).expect("fresh resume file");
        assert_eq!(resume.lobby.as_deref(), Some("Living Room"));
        assert_eq!(resume.party.players.len(), 1);
    }

    #[test]
    fn update_restart_brings_the_same_party_back() {
        let update = host_update();
        let mut s = Shared::new(vec![], "127.0.0.1:0".into(), None);
        s.update = Some(update.clone());
        let ada = join(&mut s, "Ada", "xinput:0");
        let bo = join(&mut s, "Bo", "xinput:1");
        s.dispatch(
            Command::QueueGame {
                game: GameId::new("hexstead"),
                first: false,
            },
            None,
        );
        assert!(
            s.restart_for_update().is_err(),
            "nothing to restart into yet"
        );
        std::fs::write(&update.ready, r#"{"version":"0.2.300"}"#).unwrap();
        s.refresh_update_ready();
        assert_eq!(s.snapshot().update_ready.as_deref(), Some("0.2.300"));
        s.restart_for_update().unwrap();
        assert!(s.shutdown_requested);

        let before = s.night.snapshot();
        let resume = Resume::take(&update.resume).expect("fresh resume file");
        assert!(!update.resume.exists(), "a resume file is used once");
        let mut next = Shared::new(vec![], "127.0.0.1:0".into(), None);
        let fx = next.night.restore(resume.party);
        next.apply_effects(fx, None);
        let after = next.night.snapshot();
        assert_eq!(after.players, before.players);
        assert_eq!(after.seats, before.seats);
        assert_eq!(after.playlist.entries, before.playlist.entries);
        let seat = |id| {
            after
                .seats
                .iter()
                .find(|s| s.occupant.player_id() == Some(id))
                .and_then(|s| s.controller.clone())
        };
        assert_eq!(seat(ada).as_deref(), Some("xinput:0"));
        assert_eq!(seat(bo).as_deref(), Some("xinput:1"));
        std::fs::remove_dir_all(update.ready.parent().unwrap()).unwrap();
    }

    #[test]
    fn stale_or_missing_resume_files_are_ignored() {
        let update = host_update();
        assert!(Resume::take(&update.resume).is_none());
        std::fs::write(&update.resume, b"not json").unwrap();
        assert!(Resume::take(&update.resume).is_none());
        assert!(!update.resume.exists());
        std::fs::remove_dir_all(update.ready.parent().unwrap()).unwrap();
    }
}
