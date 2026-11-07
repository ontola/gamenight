//! GameNight for Bevy.
//!
//! Add [`GameNightPlugin`] next to `DefaultPlugins` and your game joins the
//! party: the plugin connects when GameNight launched the process, follows the
//! session lifecycle, keeps the window hidden and silent until the party picks
//! your game, routes each seat's controller to the right player and re-declares
//! your settings, phone buttons and phone screen after every reconnect.
//!
//! ```no_run
//! use bevy::prelude::*;
//! use gamenight_bevy::prelude::*;
//!
//! fn main() {
//!     App::new()
//!         .add_plugins(DefaultPlugins.set(WindowPlugin {
//!             // Hidden and unfocused at launch when GameNight started us.
//!             primary_window: Some(managed_window(Window {
//!                 title: "My Game".into(),
//!                 ..default()
//!             })),
//!             ..default()
//!         }))
//!         .add_plugins(GameNightPlugin::new("my-game"))
//!         .add_systems(Update, lifecycle)
//!         .run();
//! }
//!
//! fn lifecycle(mut gn: ResMut<GameNight>, mut events: MessageReader<GameNightEvent>) {
//!     for event in events.read() {
//!         if let GameNightEvent::Prepare { seats, players, .. } = event {
//!             // Build the level for these seats, then:
//!             gn.ready();
//!         }
//!     }
//! }
//! ```
//!
//! Without a GameNight launch the same binary runs standalone: the plugin
//! seats the keyboard and every local gamepad, so your input code is the same
//! in both modes. Set `GAMENIGHT_ADDR=127.0.0.1:7912` to connect a
//! standalone build to a development host.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use bevy::app::AppExit;
use bevy::asset::RenderAssetUsages;
use bevy::audio::{AudioSink, AudioSinkPlayback};
use bevy::diagnostic::SystemInfo;
use bevy::image::{Image, ImageSampler};
use bevy::input::gamepad::{
    Gamepad, GamepadAxis, GamepadButton, GamepadRumbleIntensity, GamepadRumbleRequest,
};
use bevy::prelude::*;
use bevy::render::render_resource::{Extent3d, TextureDimension, TextureFormat};
use bevy::render::renderer::RenderAdapterInfo;
use bevy::window::{MonitorSelection, PrimaryWindow, WindowMode};
use bevy::winit::{UpdateMode, WinitSettings};

pub use gamenight_protocol::avatar::HeadLayout;
pub use gamenight_protocol::{
    Avatar, ClientMessage, CompanionApp, ControllerState, GameAction, PerformanceSample, Player,
    PlayerId, PlayerPresence, Seat, SeatOccupant, SessionId, SettingKind, SettingScope,
    SettingSpec, SettingValue,
};
pub use gamenight_sdk::GameEvent;

pub mod prelude {
    pub use crate::{
        couch_order, gameplay_runs, managed_window, GameNight, GameNightEvent, GameNightPlugin,
        Pad, PadButton, Phase,
    };
    pub use gamenight_protocol::{
        GameAction, Player, PlayerId, Seat, SeatOccupant, SettingKind, SettingScope, SettingSpec,
        SettingValue,
    };
}

/// A button on the canonical GameNight pad, in wire bit order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PadButton {
    A = 0,
    B = 1,
    X = 2,
    Y = 3,
    LeftBumper = 4,
    RightBumper = 5,
    /// Owned by GameNight: it always returns to the party. Never bind it.
    Back = 6,
    Start = 7,
    LeftStick = 8,
    RightStick = 9,
    Up = 10,
    Down = 11,
    Left = 12,
    Right = 13,
}

/// The deadzones our games settled on.
pub const STICK_DEADZONE: f32 = 0.15;
pub const TRIGGER_DEADZONE: f32 = 0.06;
/// Input older than this is neutral.
pub const STALE_INPUT: Duration = Duration::from_millis(250);
const ALL_BUTTONS: u32 = 0x3FFF;

/// Where the session stands. Gameplay runs in [`Phase::Running`] and, for a
/// game started by hand, in [`Phase::Standalone`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Phase {
    /// Not launched by GameNight: play locally.
    #[default]
    Standalone,
    /// Connected (or connecting), no session yet.
    Idle,
    /// Load the level for the given seats while hidden, then call
    /// [`GameNight::ready`].
    Preparing,
    /// Ready sent; waiting for Start. Stay hidden and quiet.
    Ready,
    /// On the TV: simulate, play audio, read input.
    Running,
    /// The party is in the lobby. Freeze simulation, timers and audio.
    Paused,
}

/// Everything GameNight tells the game, as Bevy messages. Read them with
/// `MessageReader<GameNightEvent>`.
#[derive(Message, Debug, Clone)]
pub enum GameNightEvent {
    /// Connected to the host (also after a development reconnect).
    Connected,
    /// The host went away. A managed game exits right after this.
    Disconnected,
    /// Warm up for these seats while hidden, then call [`GameNight::ready`].
    Prepare {
        session: SessionId,
        seats: Vec<Seat>,
        players: Vec<Player>,
    },
    /// The party picked this game: start the match now.
    Start { session: SessionId },
    /// Back to the lobby: freeze. The plugin already hides the window and
    /// pauses audio sinks.
    Pause { session: SessionId },
    /// The same match continues.
    Resume { session: SessionId },
    /// Clear session state. Another Prepare may follow.
    Dispose { session: SessionId },
    /// Seats or players changed (someone joined or left). Only after
    /// [`GameNight::participation`]. Apply without restarting the match.
    RosterChanged {
        seats: Vec<Seat>,
        players: Vec<Player>,
        presence: Vec<PlayerPresence>,
    },
    /// The same players picked up another name, colour, face or profile.
    /// Update them in place; never restart over it.
    PlayersUpdated { players: Vec<Player> },
    /// A party setting changed, from the app, the lobby, an LLM or your own
    /// menu via [`GameNight::set_setting`].
    SettingChanged { key: String, value: SettingValue },
    /// One player's own values for your player-scoped settings.
    PlayerSettings {
        player_id: PlayerId,
        values: BTreeMap<String, SettingValue>,
    },
    /// One player's saved progress.
    PlayerData {
        player_id: PlayerId,
        data: serde_json::Value,
    },
    /// A player pressed one of your phone buttons ([`GameNight::declare_actions`]).
    ActionTriggered { key: String, player_id: PlayerId },
    /// A phone screen sent JSON.
    CompanionMessage {
        player_id: PlayerId,
        data: serde_json::Value,
    },
    /// A phone screen opened or closed. Send that player their view when it opens.
    CompanionPresence {
        player_id: PlayerId,
        connected: bool,
    },
    /// A plain-text request ([`GameNight::declare_commands`]). Answer with
    /// [`GameNight::command_result`].
    GameCommand {
        player_id: PlayerId,
        id: String,
        text: String,
    },
    /// Host music started or stopped. Mute your music, not your effects.
    HostMusic { playing: bool },
}

/// Add this once. See the crate docs.
pub struct GameNightPlugin {
    pub game_id: String,
    /// Hide the window until Start, show it fullscreen on Start/Resume and hide
    /// it again on Pause/Dispose. Default true.
    pub manage_window: bool,
    /// Borderless fullscreen while on the TV. Default true.
    pub fullscreen: bool,
    /// Pause every playing `AudioSink` while not on the TV. Default true.
    pub manage_audio: bool,
    /// Update at 10 fps while warm or paused. Default true.
    pub throttle_when_hidden: bool,
    /// Report seat activity (presses, sticks past the deadzone) so nobody is
    /// marked asleep. Default true.
    pub report_activity: bool,
}

impl GameNightPlugin {
    pub fn new(game_id: impl Into<String>) -> Self {
        Self {
            game_id: game_id.into(),
            manage_window: true,
            fullscreen: true,
            manage_audio: true,
            throttle_when_hidden: true,
            report_activity: true,
        }
    }
}

/// Use for `WindowPlugin::primary_window`: when GameNight launched the game,
/// the window starts hidden and unfocused so warming up never steals the TV.
pub fn managed_window(mut window: Window) -> Window {
    if gamenight_sdk::GameNight::launched_by_daemon() {
        window.visible = false;
        window.focused = false;
    }
    window
}

/// Run condition: true while the game is on the TV (or standalone).
/// `.run_if(gameplay_runs)` on simulation systems freezes them on Pause.
pub fn gameplay_runs(gn: Res<GameNight>) -> bool {
    matches!(gn.phase, Phase::Running | Phase::Standalone)
}

/// `seats` left to right as the players sit on the couch. Lay out split
/// screens and anything else left to right in this order. Call it again on
/// [`GameNightEvent::PlayersUpdated`]: people move mid-match.
pub fn couch_order(seats: &[Seat], players: &[Player]) -> Vec<Seat> {
    let place: HashMap<PlayerId, u8> = players
        .iter()
        .filter_map(|p| p.couch.map(|c| (p.id, c)))
        .collect();
    let mut sorted = seats.to_vec();
    sorted.sort_by_key(|seat| {
        let at = seat
            .occupant
            .player_id()
            .and_then(|id| place.get(&id).copied())
            .map_or(1000, u32::from);
        (at, seat.index)
    });
    sorted
}

/// One seat's controller for this frame. Empty (all neutral) when the seat has
/// no controller, the input is stale or the game is not running.
#[derive(Debug, Clone, Default)]
pub struct Pad {
    axes: [i16; 6],
    buttons: u32,
    before: u32,
}

impl Pad {
    /// Raw axis, -1 to 1: left x/y, right x/y, left/right trigger.
    pub fn axis(&self, index: usize) -> f32 {
        self.axes
            .get(index)
            .map_or(0.0, |v| (*v as f32 / 32767.0).clamp(-1.0, 1.0))
    }

    /// A stick (0 left, 1 right) with a radial deadzone, rescaled to start at
    /// 0. Up is positive y, like Bevy's world.
    pub fn stick(&self, side: usize) -> Vec2 {
        self.stick_with(side, STICK_DEADZONE)
    }

    pub fn stick_with(&self, side: usize, deadzone: f32) -> Vec2 {
        // On the wire up is negative, like XInput's screen convention.
        let v = Vec2::new(self.axis(side * 2), -self.axis(side * 2 + 1));
        let length = v.length();
        if length <= deadzone {
            return Vec2::ZERO;
        }
        v / length * ((length - deadzone) / (1.0 - deadzone)).min(1.0)
    }

    /// A trigger (0 left, 1 right) from 0 to 1 with a deadzone.
    pub fn trigger(&self, side: usize) -> f32 {
        let t = self.axis(4 + side).max(0.0);
        if t <= TRIGGER_DEADZONE {
            0.0
        } else {
            (t - TRIGGER_DEADZONE) / (1.0 - TRIGGER_DEADZONE)
        }
    }

    /// Held now.
    pub fn pressed(&self, button: PadButton) -> bool {
        self.buttons & (1 << button as u32) != 0
    }

    /// Went down this frame. After Start and Resume a button still held from
    /// the lobby must be released first, so one press never does two things.
    pub fn just_pressed(&self, button: PadButton) -> bool {
        let bit = 1 << button as u32;
        self.buttons & bit != 0 && self.before & bit == 0
    }

    /// Any button or stick in use.
    pub fn active(&self) -> bool {
        self.buttons & ALL_BUTTONS & !(1 << PadButton::Back as u32) != 0
            || self.stick(0) != Vec2::ZERO
            || self.stick(1) != Vec2::ZERO
            || self.trigger(0) > 0.0
            || self.trigger(1) > 0.0
    }
}

/// The connection, the party and the session. `Res<GameNight>` to read,
/// `ResMut<GameNight>` to send.
#[derive(Resource)]
pub struct GameNight {
    /// Our game id.
    pub game_id: String,
    /// True when GameNight started this process.
    pub launched_by_daemon: bool,
    /// Connected to a host right now.
    pub connected: bool,
    pub phase: Phase,
    /// The session being prepared or played.
    pub session: Option<SessionId>,
    /// Seats of this session (or the local seats when standalone).
    pub seats: Vec<Seat>,
    /// Players of this session (or local stand-ins when standalone).
    pub players: Vec<Player>,
    pub presence: Vec<PlayerPresence>,
    host_music: bool,
    frames: HashMap<String, ControllerState>,
    frame_at: Option<Instant>,
    buttons_now: HashMap<u8, u32>,
    buttons_before: HashMap<u8, u32>,
    activity_at: HashMap<String, Instant>,
    rumbling: HashSet<u8>,
    settings: Vec<SettingSpec>,
    actions: Vec<GameAction>,
    companion: Option<ClientMessage>,
    commands: Option<ClientMessage>,
    player_settings: HashMap<PlayerId, BTreeMap<String, SettingValue>>,
    player_data: HashMap<PlayerId, (serde_json::Value, u64)>,
    ready_at: Option<u32>,
    outbox: Vec<ClientMessage>,
    local: Vec<GameNightEvent>,
    local_rumble: Vec<(u8, f32, f32, f32)>,
    connect: bool,
}

impl GameNight {
    fn new(game_id: String) -> Self {
        let launched = gamenight_sdk::GameNight::launched_by_daemon();
        let connect = launched || std::env::var(gamenight_protocol::ENV_ADDR).is_ok();
        Self {
            game_id,
            launched_by_daemon: launched,
            connected: false,
            phase: if launched {
                Phase::Idle
            } else {
                Phase::Standalone
            },
            session: None,
            seats: Vec::new(),
            players: Vec::new(),
            presence: Vec::new(),
            host_music: false,
            frames: HashMap::new(),
            frame_at: None,
            buttons_now: HashMap::new(),
            buttons_before: HashMap::new(),
            activity_at: HashMap::new(),
            rumbling: HashSet::new(),
            settings: Vec::new(),
            actions: Vec::new(),
            companion: None,
            commands: None,
            player_settings: HashMap::new(),
            player_data: HashMap::new(),
            ready_at: None,
            outbox: Vec::new(),
            local: Vec::new(),
            local_rumble: Vec::new(),
            connect,
        }
    }

    /// Whether a host session drives the game (as opposed to standalone play).
    pub fn managed(&self) -> bool {
        self.phase != Phase::Standalone
    }

    /// The game is on the TV (or standalone).
    pub fn is_running(&self) -> bool {
        matches!(self.phase, Phase::Running | Phase::Standalone)
    }

    /// Host music is playing: mute your music (not your effects).
    pub fn host_music_playing(&self) -> bool {
        self.host_music
    }

    /// The player in a seat, if a person sits there.
    pub fn player_in(&self, seat: &Seat) -> Option<&Player> {
        let id = seat.occupant.player_id()?;
        self.players.iter().find(|p| p.id == id)
    }

    pub fn player(&self, id: PlayerId) -> Option<&Player> {
        self.players.iter().find(|p| p.id == id)
    }

    // ── Lifecycle ──────────────────────────────────────────────────────────

    /// Level loaded for the prepared seats. The plugin sends Ready after two
    /// more frames, so the first frame of your level exists before Start.
    pub fn ready(&mut self) {
        if self.phase == Phase::Preparing && self.ready_at.is_none() {
            self.ready_at = Some(0);
        }
    }

    /// Opt into live roster updates. Call from Prepare, before [`Self::ready`].
    /// `instant_join`: new players can join the round in progress.
    pub fn participation(&mut self, instant_join: bool) {
        if let Some(session) = self.session {
            self.outbox.push(ClientMessage::Participation {
                session,
                instant_join,
            });
        }
    }

    /// Optional loading progress (0-100) while preparing.
    pub fn progress(&mut self, percent: u8, label: Option<String>) {
        if let Some(session) = self.session {
            self.outbox.push(ClientMessage::Progress {
                session,
                percent: percent.min(100),
                label,
            });
        }
    }

    /// A round ended. Show the result briefly and start the next round
    /// yourself: this does not end the session.
    pub fn finished(&mut self) {
        if let Some(session) = self.session {
            self.outbox.push(ClientMessage::Finished { session });
        }
    }

    /// One short line for the room log on the players' phones ("Ada wins").
    pub fn room_log(&mut self, text: impl Into<String>) {
        if let Some(session) = self.session {
            self.outbox.push(ClientMessage::RoomLog {
                session,
                text: text.into(),
            });
        }
    }

    /// Back to the party. Physical Back is handled by the host; the plugin
    /// sends this for F1. Only needed for your own on-screen "leave" item.
    pub fn request_overlay(&mut self) {
        self.outbox.push(ClientMessage::RequestOverlay);
    }

    // ── Input ──────────────────────────────────────────────────────────────

    /// This frame's controller for a seat. Neutral while not running.
    pub fn pad(&self, seat: u8) -> Pad {
        if !self.is_running() {
            return Pad::default();
        }
        self.pad_any_phase(seat)
    }

    /// The same, also while paused, for example for your own menu.
    pub fn pad_any_phase(&self, seat: u8) -> Pad {
        let state = self.frame_for_seat(seat);
        Pad {
            axes: state.map_or([0; 6], |s| s.axes),
            buttons: self.buttons_now.get(&seat).copied().unwrap_or(0),
            before: self.buttons_before.get(&seat).copied().unwrap_or(0),
        }
    }

    /// The raw host frame for a seat, matched by its controller token.
    pub fn frame_for_seat(&self, seat: u8) -> Option<&ControllerState> {
        if self.frame_at.is_none_or(|at| at.elapsed() >= STALE_INPUT) {
            return None;
        }
        let token = self.token(seat)?;
        self.frames.get(token)
    }

    fn token(&self, seat: u8) -> Option<&String> {
        self.seats
            .iter()
            .find(|s| s.index == seat)
            .and_then(|s| s.controller.as_ref())
    }

    /// Vibrate a seat's pad: `weak` the light motor, `strong` the heavy one,
    /// both 0 to 1, for `seconds` (at most 5). Each call replaces the last;
    /// call it with zeros to stop.
    pub fn rumble(&mut self, seat: u8, weak: f32, strong: f32, seconds: f32) {
        let (weak, strong) = (weak.clamp(0.0, 1.0), strong.clamp(0.0, 1.0));
        let quiet = weak == 0.0 && strong == 0.0;
        if quiet && !self.rumbling.remove(&seat) {
            return;
        }
        if !quiet {
            self.rumbling.insert(seat);
        }
        match (self.phase, self.session) {
            (Phase::Standalone, _) => self.local_rumble.push((seat, weak, strong, seconds)),
            (Phase::Running, Some(session)) => self.outbox.push(ClientMessage::Rumble {
                session,
                seat,
                weak: (weak * 65535.0) as u16,
                strong: (strong * 65535.0) as u16,
                ms: ((seconds * 1000.0) as u32).min(5000),
            }),
            _ => {}
        }
    }

    /// Tell GameNight someone really plays on this seat. The plugin already
    /// does this for presses and sticks unless you turned it off.
    pub fn report_activity(&mut self, seat: u8) {
        let (Some(session), Some(token)) = (self.session, self.token(seat).cloned()) else {
            return;
        };
        if self
            .activity_at
            .get(&token)
            .is_some_and(|at| at.elapsed() < Duration::from_secs(1))
        {
            return;
        }
        self.activity_at.insert(token.clone(), Instant::now());
        self.outbox.push(ClientMessage::ControllerInput {
            session: Some(session),
            controller: token,
        });
    }

    // ── Settings, actions, saves ───────────────────────────────────────────

    /// Declare the settings the party may change. Changes arrive as
    /// [`GameNightEvent::SettingChanged`]. Re-declared after reconnects.
    pub fn declare_settings(&mut self, settings: Vec<SettingSpec>) {
        self.settings = settings.clone();
        if self.connected {
            self.outbox
                .push(ClientMessage::DeclareSettings { settings });
        }
    }

    /// The declared settings.
    pub fn settings(&self) -> &[SettingSpec] {
        &self.settings
    }

    /// Change a setting from your own Start menu so every app shows it too.
    /// Answered with [`GameNightEvent::SettingChanged`] (also standalone).
    pub fn set_setting(&mut self, key: impl Into<String>, value: SettingValue) {
        let key = key.into();
        if self.connected {
            self.outbox.push(ClientMessage::SetSetting {
                game: None,
                key,
                value,
            });
        } else if self
            .settings
            .iter()
            .any(|s| s.key == key && s.kind.validate(&value).is_ok())
        {
            self.local
                .push(GameNightEvent::SettingChanged { key, value });
        }
    }

    /// Change one player's own value of a player-scoped setting.
    pub fn set_player_setting(
        &mut self,
        player_id: PlayerId,
        key: impl Into<String>,
        value: SettingValue,
    ) {
        let key = key.into();
        if self.connected {
            self.outbox.push(ClientMessage::SetPlayerSetting {
                game: None,
                player_id,
                key,
                value,
            });
        } else {
            let values = self.player_settings.entry(player_id).or_default();
            values.insert(key, value);
            let values = values.clone();
            self.local
                .push(GameNightEvent::PlayerSettings { player_id, values });
        }
    }

    /// A player's value for a player-scoped setting, or its declared default.
    pub fn player_setting(&self, player_id: PlayerId, key: &str) -> Option<SettingValue> {
        self.player_settings
            .get(&player_id)
            .and_then(|v| v.get(key).cloned())
            .or_else(|| {
                self.settings
                    .iter()
                    .find(|s| s.key == key)
                    .map(|s| s.kind.default_value())
            })
    }

    /// Buttons on the players' phones, next to your settings ("New round").
    /// Presses arrive as [`GameNightEvent::ActionTriggered`].
    pub fn declare_actions(&mut self, actions: Vec<GameAction>) {
        self.actions = actions.clone();
        if self.connected {
            self.outbox.push(ClientMessage::DeclareActions { actions });
        }
    }

    /// A player's saved progress (unlocks, stats), kept with their profile.
    pub fn player_data(&self, player_id: PlayerId) -> Option<&serde_json::Value> {
        self.player_data.get(&player_id).map(|(data, _)| data)
    }

    /// Save a player's progress: any JSON up to 64 KB. Guests (no
    /// `profile_key`) keep it for the night only.
    pub fn save_player_data(&mut self, player_id: PlayerId, data: serde_json::Value) {
        let revision = self.player_data.get(&player_id).map_or(0, |(_, r)| *r);
        if self.connected {
            self.outbox.push(ClientMessage::SavePlayerData {
                player_id,
                data: data.clone(),
                expected_revision: Some(revision),
            });
        }
        // Keep it locally right away; the host answers with the new revision.
        self.player_data.insert(player_id, (data.clone(), revision));
        if !self.connected {
            self.local
                .push(GameNightEvent::PlayerData { player_id, data });
        }
    }

    // ── Phone screens and commands ─────────────────────────────────────────

    /// Serve a folder of your game (with `entry` in it) as each player's
    /// phone screen. A relative folder is looked up next to the executable,
    /// under `BEVY_ASSET_ROOT` or `CARGO_MANIFEST_DIR`, then the working
    /// directory. Returns the folder it declared.
    pub fn declare_companion_folder(
        &mut self,
        folder: impl AsRef<Path>,
        entry: &str,
    ) -> Option<PathBuf> {
        let root = resolve_folder(folder.as_ref())?;
        self.companion = Some(ClientMessage::DeclareCompanion {
            root: Some(root.to_string_lossy().into_owned()),
            entry: Some(entry.to_string()),
            app: None,
        });
        if self.connected {
            self.outbox.extend(self.companion.clone());
        }
        Some(root)
    }

    /// Send JSON to one player's phone screen, or every phone with `None`.
    pub fn companion_message(&mut self, player_id: Option<PlayerId>, data: serde_json::Value) {
        if self.connected {
            self.outbox.push(ClientMessage::CompanionMessage {
                game: None,
                player_id,
                data,
            });
        }
    }

    /// Accept plain-text requests from the app and the session assistant.
    pub fn declare_commands(&mut self, description: impl Into<String>, examples: Vec<String>) {
        self.commands = Some(ClientMessage::DeclareCommands {
            description: description.into(),
            examples,
            mcp: None,
        });
        if self.connected {
            self.outbox.extend(self.commands.clone());
        }
    }

    pub fn command_result(&mut self, id: impl Into<String>, ok: bool, message: impl Into<String>) {
        self.outbox.push(ClientMessage::CommandResult {
            id: id.into(),
            ok,
            message: message.into(),
        });
    }

    /// Send any other game message.
    pub fn send(&mut self, message: ClientMessage) {
        self.outbox.push(message);
    }
}

/// A player's drawn face as a nearest-filtered texture, plus where the head
/// sits in it. Draw a circle in the skin colour underneath, then place the
/// texture so that `head.center` lands on the circle's centre, scaled by
/// `radius / head.radius`.
pub fn avatar_image(player: &Player) -> Option<(Image, HeadLayout)> {
    let avatar = Avatar::parse(player.avatar.as_deref()?)?;
    if avatar.is_blank() {
        return None;
    }
    let head = avatar.head_layout();
    let mut image = Image::new(
        Extent3d {
            width: avatar.width,
            height: avatar.height,
            depth_or_array_layers: 1,
        },
        TextureDimension::D2,
        avatar.to_rgba(),
        TextureFormat::Rgba8UnormSrgb,
        RenderAssetUsages::default(),
    );
    image.sampler = ImageSampler::nearest();
    Some((image, head))
}

/// A `#rrggbb` colour from a profile, or `fallback`.
pub fn hex_color(hex: Option<&str>, fallback: Color) -> Color {
    hex.and_then(|h| Srgba::hex(h).ok())
        .map(Color::from)
        .unwrap_or(fallback)
}

fn resolve_folder(folder: &Path) -> Option<PathBuf> {
    if folder.is_absolute() {
        return folder.is_dir().then(|| folder.to_path_buf());
    }
    let mut bases = Vec::new();
    if let Some(dir) = std::env::current_exe()
        .ok()
        .and_then(|e| e.parent().map(Path::to_path_buf))
    {
        bases.push(dir.join("assets"));
        bases.push(dir);
    }
    for var in ["BEVY_ASSET_ROOT", "CARGO_MANIFEST_DIR"] {
        if let Ok(dir) = std::env::var(var) {
            bases.push(PathBuf::from(&dir).join("assets"));
            bases.push(PathBuf::from(dir));
        }
    }
    bases.push(std::env::current_dir().ok()?.join("assets"));
    bases.push(std::env::current_dir().ok()?);
    bases
        .into_iter()
        .map(|b| b.join(folder))
        .find(|p| p.is_dir())
        .and_then(|p| p.canonicalize().ok())
}

// ── Plugin ─────────────────────────────────────────────────────────────────

impl Plugin for GameNightPlugin {
    fn build(&self, app: &mut App) {
        let gn = GameNight::new(self.game_id.clone());
        let link = if gn.connect {
            Some(spawn_network(self.game_id.clone(), gn.launched_by_daemon))
        } else {
            None
        };
        app.insert_resource(gn)
            .insert_resource(Options {
                manage_window: self.manage_window,
                fullscreen: self.fullscreen,
                manage_audio: self.manage_audio,
                throttle: self.throttle_when_hidden,
                report_activity: self.report_activity,
            })
            .init_resource::<Screen>()
            .init_resource::<Performance>()
            .add_message::<GameNightEvent>()
            .add_systems(PreUpdate, (receive, standalone_input, buttons).chain())
            .add_systems(
                Last,
                (deferred_ready, screen, performance, overlay_key, flush).chain(),
            );
        if let Some(link) = link {
            app.insert_resource(link);
        }
    }
}

#[derive(Resource)]
struct Options {
    manage_window: bool,
    fullscreen: bool,
    manage_audio: bool,
    throttle: bool,
    report_activity: bool,
}

enum Incoming {
    Connected(Box<gamenight_protocol::PartySnapshot>),
    Event(GameEvent),
    Disconnected,
}

#[derive(Resource)]
struct Link {
    incoming: Mutex<mpsc::Receiver<Incoming>>,
    outgoing: tokio::sync::mpsc::UnboundedSender<ClientMessage>,
}

/// The connection runs on its own thread, so a paused or throttled game still
/// hears Resume. Managed games stop after one connection; development
/// connections (`GAMENIGHT_ADDR` without a launch) retry every two seconds.
fn spawn_network(game_id: String, managed: bool) -> Link {
    let (in_tx, in_rx) = mpsc::channel();
    let (out_tx, mut out_rx) = tokio::sync::mpsc::unbounded_channel::<ClientMessage>();
    std::thread::Builder::new()
        .name("gamenight".into())
        .spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("tokio runtime");
            runtime.block_on(async move {
                loop {
                    match gamenight_sdk::GameNight::connect(game_id.clone(), None).await {
                        Ok(mut gn) => {
                            gn.emit_party_state(true);
                            let _ = in_tx.send(Incoming::Connected(Box::new(gn.party().clone())));
                            loop {
                                tokio::select! {
                                    biased;
                                    out = out_rx.recv() => match out {
                                        Some(msg) => if gn.send_message(&msg).await.is_err() { break },
                                        None => return,
                                    },
                                    event = gn.next_event() => match event {
                                        Ok(Some(event)) => { let _ = in_tx.send(Incoming::Event(event)); }
                                        Ok(None) => break,
                                        Err(gamenight_sdk::SdkError::Rejected(message)) => {
                                            warn!("Gamepad Party host: {message}");
                                        }
                                        Err(e) => { warn!("Gamepad Party connection: {e}"); break }
                                    },
                                }
                            }
                            if in_tx.send(Incoming::Disconnected).is_err() {
                                return;
                            }
                        }
                        Err(e) => warn!("Gamepad Party: could not connect: {e}"),
                    }
                    if managed {
                        let _ = in_tx.send(Incoming::Disconnected);
                        return;
                    }
                    tokio::time::sleep(Duration::from_secs(2)).await;
                    // Drop what queued up while offline; we re-declare on connect.
                    while out_rx.try_recv().is_ok() {}
                }
            });
        })
        .expect("spawn Gamepad Party thread");
    Link {
        incoming: Mutex::new(in_rx),
        outgoing: out_tx,
    }
}

fn receive(
    mut gn: ResMut<GameNight>,
    link: Option<Res<Link>>,
    mut out: MessageWriter<GameNightEvent>,
    mut exit: MessageWriter<AppExit>,
) {
    let local = std::mem::take(&mut gn.local);
    out.write_batch(local);
    let Some(link) = link else { return };
    let incoming: Vec<Incoming> = link.incoming.lock().unwrap().try_iter().collect();
    for message in incoming {
        match message {
            Incoming::Connected(party) => {
                gn.connected = true;
                if gn.phase == Phase::Standalone && gn.launched_by_daemon {
                    gn.phase = Phase::Idle;
                }
                set_music(&mut gn, &party, &mut out);
                // A reconnect: declare again so the host replays the values.
                let mut again = Vec::new();
                if !gn.settings.is_empty() {
                    again.push(ClientMessage::DeclareSettings {
                        settings: gn.settings.clone(),
                    });
                }
                if !gn.actions.is_empty() {
                    again.push(ClientMessage::DeclareActions {
                        actions: gn.actions.clone(),
                    });
                }
                again.extend(gn.companion.clone());
                again.extend(gn.commands.clone());
                gn.outbox.splice(0..0, again);
                out.write(GameNightEvent::Connected);
            }
            Incoming::Disconnected => {
                gn.connected = false;
                gn.frames.clear();
                out.write(GameNightEvent::Disconnected);
                if gn.launched_by_daemon {
                    info!("Gamepad Party host went away; exiting");
                    exit.write(AppExit::Success);
                }
            }
            Incoming::Event(event) => handle(&mut gn, event, &mut out),
        }
    }
}

fn set_music(
    gn: &mut GameNight,
    party: &gamenight_protocol::PartySnapshot,
    out: &mut MessageWriter<GameNightEvent>,
) {
    let playing = party.now_playing.as_ref().is_some_and(|n| n.playing);
    if playing != gn.host_music {
        gn.host_music = playing;
        out.write(GameNightEvent::HostMusic { playing });
    }
}

fn hold_buttons(gn: &mut GameNight) {
    let seats: Vec<u8> = gn.seats.iter().map(|s| s.index).collect();
    for seat in seats {
        gn.buttons_now.insert(seat, ALL_BUTTONS);
    }
}

fn handle(gn: &mut GameNight, event: GameEvent, out: &mut MessageWriter<GameNightEvent>) {
    let ours = |gn: &GameNight, s: &SessionId| gn.session.as_ref() == Some(s);
    match event {
        GameEvent::ControllerFrame { controllers } => {
            gn.frames.clear();
            gn.frame_at = Some(Instant::now());
            for state in controllers {
                gn.frames.entry(state.controller.clone()).or_insert(state);
            }
        }
        GameEvent::Prepare {
            session,
            seats,
            players,
        } => {
            if gn.session == Some(session) {
                return;
            }
            if let Some(old) = gn.session.take() {
                out.write(GameNightEvent::Dispose { session: old });
            }
            gn.session = Some(session);
            gn.phase = Phase::Preparing;
            gn.ready_at = None;
            gn.frames.clear();
            gn.seats = seats.clone();
            gn.players = players.clone();
            out.write(GameNightEvent::Prepare {
                session,
                seats,
                players,
            });
        }
        GameEvent::Start { session } if ours(gn, &session) && gn.phase == Phase::Ready => {
            gn.phase = Phase::Running;
            hold_buttons(gn);
            out.write(GameNightEvent::Start { session });
        }
        GameEvent::Pause { session } if ours(gn, &session) && gn.phase == Phase::Running => {
            gn.phase = Phase::Paused;
            out.write(GameNightEvent::Pause { session });
        }
        GameEvent::Resume { session } if ours(gn, &session) && gn.phase == Phase::Paused => {
            gn.phase = Phase::Running;
            hold_buttons(gn);
            out.write(GameNightEvent::Resume { session });
        }
        GameEvent::Dispose { session } if ours(gn, &session) => {
            gn.session = None;
            gn.phase = Phase::Idle;
            gn.ready_at = None;
            gn.frames.clear();
            gn.rumbling.clear();
            out.write(GameNightEvent::Dispose { session });
        }
        GameEvent::PartyUpdated {
            session,
            seats,
            players,
            presence,
        } if ours(gn, &session) => {
            gn.seats = seats.clone();
            gn.players = players.clone();
            gn.presence = presence.clone();
            out.write(GameNightEvent::RosterChanged {
                seats,
                players,
                presence,
            });
        }
        GameEvent::PlayersUpdated { session, players } if ours(gn, &session) => {
            for player in &players {
                match gn.players.iter_mut().find(|p| p.id == player.id) {
                    Some(known) => *known = player.clone(),
                    None => gn.players.push(player.clone()),
                }
            }
            out.write(GameNightEvent::PlayersUpdated { players });
        }
        GameEvent::SettingChanged { key, value } => {
            out.write(GameNightEvent::SettingChanged { key, value });
        }
        GameEvent::PlayerSettings { player_id, values } => {
            gn.player_settings.insert(player_id, values.clone());
            out.write(GameNightEvent::PlayerSettings { player_id, values });
        }
        GameEvent::PlayerData {
            player_id,
            data,
            revision,
        } => {
            gn.player_data.insert(player_id, (data.clone(), revision));
            out.write(GameNightEvent::PlayerData { player_id, data });
        }
        GameEvent::ActionTriggered { key, player_id } => {
            out.write(GameNightEvent::ActionTriggered { key, player_id });
        }
        GameEvent::CompanionMessage { player_id, data } => {
            out.write(GameNightEvent::CompanionMessage { player_id, data });
        }
        GameEvent::CompanionPresence {
            player_id,
            connected,
        } => {
            out.write(GameNightEvent::CompanionPresence {
                player_id,
                connected,
            });
        }
        GameEvent::GameCommand {
            player_id,
            id,
            text,
        } => {
            out.write(GameNightEvent::GameCommand {
                player_id,
                id,
                text,
            });
        }
        GameEvent::PartyState { party } => set_music(gn, &party, out),
        _ => {}
    }
}

/// Standalone, every local gamepad gets a seat of its own after the keyboard,
/// so the game reads input the same way as under GameNight.
fn standalone_input(
    mut gn: ResMut<GameNight>,
    keys: Option<Res<ButtonInput<KeyCode>>>,
    gamepads: Query<(Entity, &Gamepad)>,
    mut rumble: MessageWriter<GamepadRumbleRequest>,
    mut known: Local<Vec<Entity>>,
) {
    if gn.phase != Phase::Standalone {
        return;
    }
    let mut pads: Vec<Entity> = gamepads.iter().map(|(e, _)| e).collect();
    pads.sort();
    if *known != pads || gn.seats.is_empty() {
        *known = pads.clone();
        let (seats, players) = local_party(pads.len());
        let changed = !gn.seats.is_empty();
        gn.seats = seats.clone();
        gn.players = players.clone();
        if changed {
            gn.local.push(GameNightEvent::RosterChanged {
                seats,
                players,
                presence: Vec::new(),
            });
        }
    }
    gn.frames.clear();
    gn.frame_at = Some(Instant::now());
    if let Some(keys) = keys {
        gn.frames.insert("keyboard".into(), keyboard_state(&keys));
    }
    for (i, (_, pad)) in pads
        .iter()
        .filter_map(|e| gamepads.get(*e).ok())
        .enumerate()
    {
        gn.frames
            .insert(format!("pad:{i}"), gamepad_state(format!("pad:{i}"), pad));
    }
    for (seat, weak, strong, seconds) in std::mem::take(&mut gn.local_rumble) {
        let Some(&gamepad) = (seat as usize).checked_sub(1).and_then(|i| pads.get(i)) else {
            continue;
        };
        rumble.write(GamepadRumbleRequest::Stop { gamepad });
        if weak > 0.0 || strong > 0.0 {
            rumble.write(GamepadRumbleRequest::Add {
                gamepad,
                duration: Duration::from_secs_f32(seconds.clamp(0.0, 5.0)),
                intensity: GamepadRumbleIntensity {
                    strong_motor: strong,
                    weak_motor: weak,
                },
            });
        }
    }
}

const LOCAL_COLORS: [&str; 8] = [
    "#ef4444", "#3b82f6", "#22c55e", "#eab308", "#a855f7", "#f97316", "#14b8a6", "#ec4899",
];

fn local_party(pads: usize) -> (Vec<Seat>, Vec<Player>) {
    let mut seats = Vec::new();
    let mut players = Vec::new();
    for i in 0..=pads.min(7) {
        let id = PlayerId(uuid::Uuid::from_u128(0x6a6e_0000 + i as u128));
        let controller = if i == 0 {
            "keyboard".to_string()
        } else {
            format!("pad:{}", i - 1)
        };
        seats.push(Seat {
            index: i as u8,
            occupant: SeatOccupant::Local { player_id: id },
            controller: Some(controller),
        });
        players.push(Player {
            id,
            name: format!("Player {}", i + 1),
            color: Some(LOCAL_COLORS[i % LOCAL_COLORS.len()].into()),
            skin_color: None,
            avatar: None,
            library: Vec::new(),
            profile_key: None,
            couch: Some(i as u8),
        });
    }
    (seats, players)
}

fn keyboard_state(keys: &ButtonInput<KeyCode>) -> ControllerState {
    let held = |codes: &[KeyCode]| codes.iter().any(|k| keys.pressed(*k));
    let axis = |neg: &[KeyCode], pos: &[KeyCode]| (held(pos) as i16 - held(neg) as i16) * 32767;
    let mut buttons = 0u32;
    let mut set = |b: PadButton, codes: &[KeyCode]| {
        if held(codes) {
            buttons |= 1 << b as u32;
        }
    };
    set(PadButton::A, &[KeyCode::Space, KeyCode::Enter]);
    set(PadButton::B, &[KeyCode::ShiftLeft, KeyCode::Backspace]);
    set(PadButton::X, &[KeyCode::KeyJ]);
    set(PadButton::Y, &[KeyCode::KeyK]);
    set(PadButton::Start, &[KeyCode::Escape]);
    set(PadButton::Up, &[KeyCode::ArrowUp, KeyCode::KeyW]);
    set(PadButton::Down, &[KeyCode::ArrowDown, KeyCode::KeyS]);
    set(PadButton::Left, &[KeyCode::ArrowLeft, KeyCode::KeyA]);
    set(PadButton::Right, &[KeyCode::ArrowRight, KeyCode::KeyD]);
    ControllerState {
        controller: "keyboard".into(),
        axes: [
            axis(
                &[KeyCode::KeyA, KeyCode::ArrowLeft],
                &[KeyCode::KeyD, KeyCode::ArrowRight],
            ),
            // Wire convention: up is negative.
            -axis(
                &[KeyCode::KeyS, KeyCode::ArrowDown],
                &[KeyCode::KeyW, KeyCode::ArrowUp],
            ),
            0,
            0,
            0,
            0,
        ],
        buttons,
    }
}

fn gamepad_state(controller: String, pad: &Gamepad) -> ControllerState {
    let value = |a: GamepadAxis| (pad.get(a).unwrap_or(0.0).clamp(-1.0, 1.0) * 32767.0) as i16;
    let trigger = |b: GamepadButton| (pad.get(b).unwrap_or(0.0).clamp(0.0, 1.0) * 32767.0) as i16;
    let map = [
        (PadButton::A, GamepadButton::South),
        (PadButton::B, GamepadButton::East),
        (PadButton::X, GamepadButton::West),
        (PadButton::Y, GamepadButton::North),
        (PadButton::LeftBumper, GamepadButton::LeftTrigger),
        (PadButton::RightBumper, GamepadButton::RightTrigger),
        (PadButton::Back, GamepadButton::Select),
        (PadButton::Start, GamepadButton::Start),
        (PadButton::LeftStick, GamepadButton::LeftThumb),
        (PadButton::RightStick, GamepadButton::RightThumb),
        (PadButton::Up, GamepadButton::DPadUp),
        (PadButton::Down, GamepadButton::DPadDown),
        (PadButton::Left, GamepadButton::DPadLeft),
        (PadButton::Right, GamepadButton::DPadRight),
    ];
    let buttons = map
        .iter()
        .filter(|(_, b)| pad.pressed(*b))
        .fold(0, |acc, (bit, _)| acc | 1 << *bit as u32);
    ControllerState {
        controller,
        axes: [
            value(GamepadAxis::LeftStickX),
            -value(GamepadAxis::LeftStickY),
            value(GamepadAxis::RightStickX),
            -value(GamepadAxis::RightStickY),
            trigger(GamepadButton::LeftTrigger2),
            trigger(GamepadButton::RightTrigger2),
        ],
        buttons,
    }
}

/// Press edges per seat, and activity reports.
fn buttons(mut gn: ResMut<GameNight>, options: Res<Options>) {
    let gn = &mut *gn;
    gn.buttons_before = std::mem::take(&mut gn.buttons_now);
    let seats: Vec<u8> = gn.seats.iter().map(|s| s.index).collect();
    for seat in seats {
        // After Start/Resume `buttons_before` is all ones for one frame, so a
        // button still held from the lobby is never a fresh press.
        let held = gn.frame_for_seat(seat).map_or(0, |f| f.buttons);
        gn.buttons_now.insert(seat, held);
        if options.report_activity && gn.phase == Phase::Running && gn.pad(seat).active() {
            gn.report_activity(seat);
        }
    }
}

fn deferred_ready(mut gn: ResMut<GameNight>) {
    let Some(frames) = gn.ready_at else { return };
    if gn.phase != Phase::Preparing {
        return;
    }
    if frames < 2 {
        gn.ready_at = Some(frames + 1);
        return;
    }
    gn.ready_at = None;
    gn.phase = Phase::Ready;
    if let Some(session) = gn.session {
        gn.outbox.push(ClientMessage::Ready { session });
    }
}

#[derive(Resource, Default)]
struct Screen {
    shown: Option<bool>,
    paused_sinks: Vec<Entity>,
}

/// Hidden, silent and throttled unless on the TV.
fn screen(
    gn: Res<GameNight>,
    options: Res<Options>,
    mut state: ResMut<Screen>,
    mut window: Query<&mut Window, With<PrimaryWindow>>,
    mut sinks: Query<(Entity, &mut AudioSink)>,
    winit: Option<ResMut<WinitSettings>>,
) {
    if !gn.managed() {
        return;
    }
    let show = gn.phase == Phase::Running;
    if options.throttle {
        if let Some(mut winit) = winit {
            let mode = if show || gn.phase == Phase::Preparing {
                UpdateMode::Continuous
            } else {
                UpdateMode::reactive_low_power(Duration::from_millis(100))
            };
            if winit.focused_mode != mode {
                winit.focused_mode = mode;
                winit.unfocused_mode = mode;
            }
        }
    }
    if options.manage_audio {
        if show {
            for entity in state.paused_sinks.drain(..) {
                if let Ok((_, sink)) = sinks.get(entity) {
                    sink.play();
                }
            }
        } else {
            for (entity, sink) in &mut sinks {
                if !sink.is_paused() {
                    sink.pause();
                    state.paused_sinks.push(entity);
                }
            }
        }
    }
    if options.manage_window && state.shown != Some(show) {
        if let Ok(mut window) = window.single_mut() {
            info!(
                "[gamenight] {} the screen",
                if show { "taking" } else { "leaving" }
            );
            if show {
                if options.fullscreen {
                    window.mode = WindowMode::BorderlessFullscreen(MonitorSelection::Current);
                }
                window.visible = true;
                window.focused = true;
            } else {
                window.mode = WindowMode::Windowed;
                window.visible = false;
            }
            state.shown = Some(show);
        }
    }
}

#[derive(Resource, Default)]
struct Performance {
    session: Option<SessionId>,
    last: Option<Instant>,
    sample: PerformanceSample,
    sent_us: u64,
}

/// Active frame intervals, reported every ten seconds of play.
fn performance(
    mut gn: ResMut<GameNight>,
    mut perf: ResMut<Performance>,
    info: Option<Res<SystemInfo>>,
    adapter: Option<Res<RenderAdapterInfo>>,
    window: Query<&Window, With<PrimaryWindow>>,
) {
    if perf.session != gn.session {
        *perf = Performance {
            session: gn.session,
            ..default()
        };
    }
    let (Phase::Running, Some(session)) = (gn.phase, gn.session) else {
        perf.last = None;
        return;
    };
    let now = Instant::now();
    let elapsed = perf
        .last
        .map_or(0, |l| now.duration_since(l).as_micros() as u64);
    perf.last = Some(now);
    if elapsed == 0 || elapsed > 2_000_000 {
        return;
    }
    let sample = &mut perf.sample;
    sample.frames += 1;
    sample.elapsed_us += elapsed;
    sample.slow_frames += u64::from(elapsed > 33_333);
    sample.max_frame_us = sample.max_frame_us.max(elapsed);
    if sample.elapsed_us - perf.sent_us < 10_000_000 {
        return;
    }
    let mut sample = perf.sample.clone();
    if let Some(info) = info {
        sample.cpu = info.cpu.chars().take(128).collect();
        sample.os = info.os.chars().take(128).collect();
        sample.memory_mib = parse_memory_mib(&info.memory);
    }
    if let Some(adapter) = adapter {
        sample.gpu = adapter.name.chars().take(128).collect();
    }
    if let Ok(window) = window.single() {
        sample.width = window.physical_width();
        sample.height = window.physical_height();
    }
    perf.sent_us = perf.sample.elapsed_us;
    if sample.valid() {
        gn.outbox
            .push(ClientMessage::Performance { session, sample });
    }
}

/// "15.6 GiB" → 15974.
fn parse_memory_mib(text: &str) -> u64 {
    let mut parts = text.split_whitespace();
    let value: f64 = parts.next().and_then(|v| v.parse().ok()).unwrap_or(0.0);
    match parts.next() {
        Some("GiB") | Some("GB") => (value * 1024.0) as u64,
        Some("MiB") | Some("MB") => value as u64,
        _ => 0,
    }
}

/// F1 asks for the party (physical Back is the host's own).
fn overlay_key(mut gn: ResMut<GameNight>, keys: Option<Res<ButtonInput<KeyCode>>>) {
    if gn.connected && keys.is_some_and(|k| k.just_pressed(KeyCode::F1)) {
        gn.request_overlay();
    }
}

fn flush(mut gn: ResMut<GameNight>, link: Option<Res<Link>>) {
    let messages = std::mem::take(&mut gn.outbox);
    if let Some(link) = link {
        if gn.connected {
            for message in messages {
                let _ = link.outgoing.send(message);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seat(index: u8, id: PlayerId) -> Seat {
        Seat {
            index,
            occupant: SeatOccupant::Local { player_id: id },
            controller: Some(format!("c{index}")),
        }
    }

    #[test]
    fn couch_order_follows_the_sofa() {
        let (_, mut players) = local_party(2);
        players[0].couch = Some(2);
        players[1].couch = Some(0);
        players[2].couch = Some(1);
        let seats: Vec<Seat> = players
            .iter()
            .enumerate()
            .map(|(i, p)| seat(i as u8, p.id))
            .collect();
        let order: Vec<u8> = couch_order(&seats, &players)
            .iter()
            .map(|s| s.index)
            .collect();
        assert_eq!(order, vec![1, 2, 0]);
    }

    #[test]
    fn sticks_have_a_deadzone_and_up_is_positive() {
        let pad = Pad {
            axes: [0, -32767, 3000, 0, 0, 32767],
            buttons: 0,
            before: 0,
        };
        assert_eq!(pad.stick(0), Vec2::new(0.0, 1.0));
        assert_eq!(pad.stick(1), Vec2::ZERO);
        assert!((pad.trigger(1) - 1.0).abs() < 1e-5);
    }

    #[test]
    fn held_buttons_need_a_release_after_start() {
        let pad = Pad {
            axes: [0; 6],
            buttons: 1,
            before: ALL_BUTTONS,
        };
        assert!(pad.pressed(PadButton::A));
        assert!(!pad.just_pressed(PadButton::A));
        let pad = Pad {
            axes: [0; 6],
            buttons: 1,
            before: 0,
        };
        assert!(pad.just_pressed(PadButton::A));
    }

    #[test]
    fn memory_text_parses() {
        assert_eq!(parse_memory_mib("16.0 GiB"), 16384);
        assert_eq!(parse_memory_mib("?"), 0);
    }
}
