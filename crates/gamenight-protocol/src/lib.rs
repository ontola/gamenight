//! The GameNight wire protocol.
//!
//! Everything that crosses a process boundary — daemon ⇄ game, daemon ⇄ overlay —
//! is defined here and nowhere else. Engine plugins are convenience; this
//! protocol is the product.
//!
//! Transport: WebSocket, one JSON object per text frame. Every message is a
//! tagged enum (`"type"` field, snake_case). Unknown fields must be ignored by
//! receivers so the protocol can grow without breaking old SDKs.

pub mod artwork;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub mod avatar;
pub use avatar::Avatar;

/// Bumped only on breaking changes. Additive changes (new message types, new
/// optional fields) do not bump this.
pub const PROTOCOL_VERSION: u32 = 1;

/// Default address the daemon listens on.
pub const DEFAULT_ADDR: &str = "127.0.0.1:7912";

/// Port the web server (profile studio, join pages) listens on.
pub const DEFAULT_WEB_PORT: u16 = 7913;

/// This machine's address on the local network, for URLs that have to be
/// reachable from someone else's phone.
///
/// A join link is useless if it says `127.0.0.1` — on a phone that resolves
/// to the phone. So anything printed onto a QR code needs the LAN address
/// instead, which is what this finds.
///
/// The trick is the standard one: a UDP socket is *connected* to an address
/// out on the internet, which makes the OS pick the interface it would route
/// through and assign that interface's local address — then we read it back.
/// UDP connect sends no packets, so this touches the network not at all and
/// works with no internet connection; it only needs a route to exist.
/// `None` when there's no such route (fully offline, no LAN), where callers
/// should fall back to loopback rather than print something wrong.
pub fn lan_ip() -> Option<std::net::IpAddr> {
    let socket = std::net::UdpSocket::bind("0.0.0.0:0").ok()?;
    // Any routable address works; nothing is sent to it.
    socket.connect("203.0.113.1:80").ok()?;
    let ip = socket.local_addr().ok()?.ip();
    if ip.is_loopback() || ip.is_unspecified() {
        return None;
    }
    Some(ip)
}

/// The base URL of the web server as reachable from another device on the
/// network, e.g. `http://192.168.1.42:7913`. Falls back to loopback when
/// there's no LAN address to offer.
pub fn web_base_url() -> String {
    match lan_ip() {
        Some(ip) => format!("http://{ip}:{DEFAULT_WEB_PORT}"),
        None => format!("http://127.0.0.1:{DEFAULT_WEB_PORT}"),
    }
}

// ---------------------------------------------------------------------------
// The launch environment contract
// ---------------------------------------------------------------------------
// When the daemon launches a game process it sets these variables. SDKs
// auto-detect them so the same binary boots into game-night mode when
// launched by the daemon and runs standalone otherwise — no CLI flags needed
// (unknown flags break existing games; extra env vars are invisible).

/// Set to `1` when the process was launched by a GameNight daemon.
pub const ENV_GAMENIGHT: &str = "GAMENIGHT";
/// The daemon's WebSocket address, e.g. `127.0.0.1:7912`.
pub const ENV_ADDR: &str = "GAMENIGHT_ADDR";
/// The game id this process was launched to serve.
pub const ENV_GAME_ID: &str = "GAMENIGHT_GAME_ID";
/// Per-launch secret; must be echoed in the `hello`.
pub const ENV_TOKEN: &str = "GAMENIGHT_TOKEN";
/// The party overlay's URL/file path, forwarded from the daemon's own
/// environment so a game can raise it (e.g. on a controller Guide-button
/// press) without per-game configuration. Optional — unset means no games on
/// this machine can raise the overlay from inside a match.
pub const ENV_OVERLAY_URL: &str = "GAMENIGHT_OVERLAY_URL";

// ---------------------------------------------------------------------------
// Identifiers
// ---------------------------------------------------------------------------

/// A player in the party. Stable for the lifetime of the party, across games.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct PlayerId(pub Uuid);

impl PlayerId {
    pub fn new() -> Self {
        Self(Uuid::new_v4())
    }
}

impl Default for PlayerId {
    fn default() -> Self {
        Self::new()
    }
}

/// A single playable game instance. Sessions are disposable; ids are not reused.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct SessionId(pub Uuid);

impl SessionId {
    pub fn new() -> Self {
        Self(Uuid::new_v4())
    }
}

impl Default for SessionId {
    fn default() -> Self {
        Self::new()
    }
}

/// Identifies a game *title* (e.g. `"towerfall"`), not a running instance.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct GameId(pub String);

impl GameId {
    pub fn new(id: impl Into<String>) -> Self {
        Self(id.into())
    }
}

impl std::fmt::Display for GameId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.0.fmt(f)
    }
}

// ---------------------------------------------------------------------------
// Party model
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Player {
    pub id: PlayerId,
    pub name: String,
    /// Game-controlled clothing/team colour (`#rrggbb`). Games may override
    /// it without changing the personal `skin_color` preference.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    /// Personal skin colour (#rrggbb), independent of game/team clothing colours.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub skin_color: Option<String>,
    /// Pixel art the player drew for themselves in the studio.
    ///
    /// Opaque on the wire so the encoding can evolve without a protocol
    /// bump — decode it with [`Avatar::parse`] rather than reading the
    /// string directly, and games get RGBA they can upload as a texture.
    /// See the [`avatar`] module for the format.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub avatar: Option<String>,
    /// Games owned in this player's profile library, shared with the party.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub library: Vec<GameId>,
}

/// Presence is separate from identity: sleeping never releases a seat.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PresenceState {
    Active,
    Warning,
    Sleeping,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlayerPresence {
    pub player_id: PlayerId,
    pub state: PresenceState,
}

/// Who (or what) fills a seat. Games receive seats, never raw controller ids.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SeatOccupant {
    /// A player on this machine.
    Local { player_id: PlayerId },
    /// A player connected over the network (future phase, already on the wire).
    Remote { player_id: PlayerId },
    /// A bot fills the seat.
    Ai,
    /// Nobody. Games may hide or skip empty seats.
    Empty,
}

impl SeatOccupant {
    pub fn player_id(&self) -> Option<PlayerId> {
        match self {
            SeatOccupant::Local { player_id } | SeatOccupant::Remote { player_id } => {
                Some(*player_id)
            }
            _ => None,
        }
    }

    pub fn is_empty(&self) -> bool {
        matches!(self, SeatOccupant::Empty)
    }
}

/// A playable position. Seat indices are stable across games so player 2 stays
/// player 2 all night.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Seat {
    pub index: u8,
    pub occupant: SeatOccupant,
    /// Opaque platform hint (e.g. `"xinput:0"`). Games should not need it; the
    /// daemon owns input routing.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub controller: Option<String>,
}

// ---------------------------------------------------------------------------
// Sessions & playlist
// ---------------------------------------------------------------------------

/// Session lifecycle. Legal transitions are enforced by `gamenight-core`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionPhase {
    Created,
    Preparing,
    Ready,
    Running,
    Paused,
    Finished,
    Disposed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionInfo {
    pub id: SessionId,
    pub game: GameId,
    pub phase: SessionPhase,
    /// How far along loading is, 0 to 100, if the game bothers to say.
    /// Optional on purpose: a game that loads instantly has nothing to
    /// report, and screens must stay honest without it (see `Progress`).
    ///
    /// Whole percent rather than a fraction — it's what screens display, and
    /// it keeps every type on the wire comparable.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub progress: Option<u8>,
    /// What it's doing right now ("generating arena"), if the game says.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub progress_label: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlaylistEntry {
    pub game: GameId,
    pub title: String,
}

/// Where a background install has got to. Distinct from `SessionPhase` on
/// purpose: a game being fetched has no process and no session, so none of
/// the session lifecycle applies to it — it isn't warming, it isn't loading,
/// it isn't on the shelf yet. It's arriving.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum InstallState {
    /// In the queue, nothing happening yet.
    Queued,
    /// Bytes are moving. This is the only state with a meaningful `percent`.
    Downloading,
    /// Downloaded; checking it against the catalogue's sha256.
    Verifying,
    /// Hash matched; unpacking it into place.
    Extracting,
    /// Playable. The shelf entry appears in the same snapshot.
    Installed,
    /// Gave up. `label` carries why, because a party staring at a stalled
    /// bar deserves to know whether to wait or pick something else.
    Failed,
}

/// One game arriving in the background, for any screen that wants to show
/// the party what's on its way.
///
/// Progress lives here rather than on `SessionInfo` because a download
/// happens *before* there is anything to have a session about — the process
/// doesn't exist, so it cannot report on itself the way a warming game does.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InstallStatus {
    pub game: GameId,
    /// The catalogue title, so a screen can name it without a shelf entry —
    /// which by definition doesn't exist yet while this is downloading.
    pub title: String,
    pub state: InstallState,
    /// Whole percent of the download, 0 to 100. Only `Downloading` sets it:
    /// verifying and extracting are fast and their duration is unknowable,
    /// so a bar for them would be a lie.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub percent: Option<u8>,
    /// Human-readable detail — the failure reason, or a step's name.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
}

/// Music playing on the host machine, from whatever the person who's hosting
/// already had on — Spotify, Apple Music — read straight off the OS.
///
/// The party's music is part of the evening, not part of any game: somebody
/// puts a record on before the first match and it runs all night. Showing it
/// in the lobby (and letting anyone with a controller skip a track they hate)
/// means nobody has to walk to the host's laptop, which is the only reason
/// that laptop's owner ends up being the evening's DJ.
///
/// Absent from the snapshot entirely when nothing is on — see
/// `PartySnapshot::now_playing`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NowPlaying {
    pub title: String,
    /// Empty when the source doesn't know one (a podcast, a local file with
    /// no tags) — screens should just show the title alone.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub artist: String,
    /// Whether it's actually making sound right now. A paused track still
    /// appears, so the pad that paused it is also the pad that resumes it.
    pub playing: bool,
    /// Which app it's coming from ("Spotify"), so a screen can say where to
    /// go when the party wants something this control surface can't do.
    pub source: String,
}

/// What a player can ask of the host's music. Deliberately the three things
/// a room full of people actually shout about — no volume (that's the amp's
/// job and the host's call), no seeking, no library browsing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MediaAction {
    /// Pause if playing, resume if paused — one pad, both jobs, because the
    /// party can see which it is from the same card the pad sits under.
    PlayPause,
    NextTrack,
    PreviousTrack,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlaylistSnapshot {
    pub entries: Vec<PlaylistEntry>,
    /// Index of the entry the *active* session is playing, if any.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub current: Option<usize>,
}

/// How the daemon starts a game process. The handshake context (address,
/// game id, launch token) is passed via the `GAMENIGHT_*` environment
/// variables, not arguments, so unmodified binaries launch cleanly.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LaunchSpec {
    /// Executable path (absolute, or relative to the daemon's working dir).
    pub command: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub args: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    /// Extra environment for the process (the `GAMENIGHT_*` vars are added on
    /// top and cannot be overridden here).
    #[serde(default, skip_serializing_if = "std::collections::BTreeMap::is_empty")]
    pub env: std::collections::BTreeMap<String, String>,
}

/// Presentation metadata for a title in the game library — everything an
/// overlay needs to sell the next game: cover art and all that.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GameMeta {
    pub id: GameId,
    pub title: String,
    /// One-line pitch shown under the title.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tagline: Option<String>,
    /// Single PNG icon/cover: HTTPS URL, PNG data URI, or (in shelf files)
    /// relative PNG path resolved by the daemon. Absent = overlays generate a cover from
    /// `color` + `emoji`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cover: Option<String>,
    /// Accent color (`#rrggbb`) for generated covers and highlights.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    /// Icon for generated covers.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub emoji: Option<String>,
    /// Human-readable player range, e.g. `"2–4"`. Display only — the daemon
    /// picks games by `min_players`/`max_players`, never by parsing this.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub players: Option<String>,
    /// Couch seats this game supports. The daemon uses these to warm
    /// something that actually fits the party, so a shelf entry without them
    /// is treated as "fits anything" rather than being skipped — an unknown
    /// range should not make a game unplayable.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub min_players: Option<u8>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_players: Option<u8>,
    /// The count the game shines at, used to break ties between games that
    /// all merely fit.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub best_players: Option<u8>,
    /// How to start this game. Absent = the daemon waits for the process to
    /// show up on its own (dev mode / externally managed).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub launch: Option<LaunchSpec>,
}

impl GameMeta {
    /// Whether this game can be played by `players` people on one couch.
    ///
    /// An empty party (nobody has joined yet) fits everything: the lobby
    /// should still have something warm ready before the first person sits
    /// down, and refusing to warm anything until someone joins would make the
    /// first transition slow for no reason.
    ///
    /// A missing bound is permissive in that direction. A shelf entry with no
    /// declared range is playable at any count rather than never playable —
    /// silently unplayable games are far harder to notice than a bad fit.
    pub fn fits_players(&self, players: u8) -> bool {
        if players == 0 {
            return true;
        }
        self.min_players.is_none_or(|min| players >= min)
            && self.max_players.is_none_or(|max| players <= max)
    }

    /// How well this game suits `players`, lower being better. Used only to
    /// order games that already fit.
    pub fn fit_distance(&self, players: u8) -> u8 {
        match self.best_players {
            Some(best) => best.abs_diff(players),
            // No declared sweet spot: treat the low end as the intent, which
            // is where a "2–8" party game usually plays best.
            None => self.min_players.map_or(0, |min| min.abs_diff(players)),
        }
    }
}

// ---------------------------------------------------------------------------
// Match settings
// ---------------------------------------------------------------------------
// Games declare the knobs a party may turn (items on/off, stock count, arena
// choice); the daemon owns the current values, validates every write, and
// pushes changes to the game live. Anything that can speak the protocol can
// turn the knobs — the overlay, or an LLM via `gamenight-mcp` ("hey
// GameNight, disable items").

/// A match-setting value on the wire: plain JSON scalars, no tagging.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum SettingValue {
    Toggle(bool),
    Number(i64),
    Choice(String),
}

impl std::fmt::Display for SettingValue {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SettingValue::Toggle(b) => b.fmt(f),
            SettingValue::Number(n) => n.fmt(f),
            SettingValue::Choice(s) => s.fmt(f),
        }
    }
}

/// What kind of knob a setting is, its default, and what values it accepts.
/// Flattened into [`SettingSpec`] on the wire (`"kind": "toggle"`, …).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SettingKind {
    /// On/off.
    Toggle { default: bool },
    /// An integer in `min..=max` (stock count, time limit, score cap).
    Number { default: i64, min: i64, max: i64 },
    /// One of a fixed set of options (arena, game mode).
    Choice {
        default: String,
        options: Vec<String>,
    },
}

impl SettingKind {
    pub fn default_value(&self) -> SettingValue {
        match self {
            SettingKind::Toggle { default } => SettingValue::Toggle(*default),
            SettingKind::Number { default, .. } => SettingValue::Number(*default),
            SettingKind::Choice { default, .. } => SettingValue::Choice(default.clone()),
        }
    }

    /// Would `value` be a legal value for this setting? Error strings are
    /// written to be shown verbatim — to a human or to an LLM correcting
    /// itself.
    pub fn validate(&self, value: &SettingValue) -> Result<(), String> {
        match (self, value) {
            (SettingKind::Toggle { .. }, SettingValue::Toggle(_)) => Ok(()),
            (SettingKind::Number { min, max, .. }, SettingValue::Number(n)) => {
                if (*min..=*max).contains(n) {
                    Ok(())
                } else {
                    Err(format!(
                        "must be an integer between {min} and {max}, got {n}"
                    ))
                }
            }
            (SettingKind::Choice { options, .. }, SettingValue::Choice(c)) => {
                if options.contains(c) {
                    Ok(())
                } else {
                    Err(format!(
                        "must be one of [{}], got '{c}'",
                        options.join(", ")
                    ))
                }
            }
            (SettingKind::Toggle { .. }, other) => {
                Err(format!("expected true or false, got {other}"))
            }
            (SettingKind::Number { min, max, .. }, other) => Err(format!(
                "expected an integer between {min} and {max}, got {other}"
            )),
            (SettingKind::Choice { options, .. }, other) => Err(format!(
                "expected one of [{}], got {other}",
                options.join(", ")
            )),
        }
    }
}

/// One knob a game exposes to the party.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SettingSpec {
    /// Stable identifier (`"items"`, `"stock"`). Unique within the game.
    pub key: String,
    /// Human-readable name (`"Items"`, `"Stock count"`).
    pub label: String,
    /// What the knob does — worth writing well: this is what overlays show
    /// and what an LLM reads to map "disable items" onto a key.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(flatten)]
    pub kind: SettingKind,
}

/// A game's declared settings plus their current values, as broadcast in
/// every [`PartySnapshot`]. Values are effective (defaults merged in) and
/// survive the game process reconnecting.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct GameSettings {
    pub game: GameId,
    pub specs: Vec<SettingSpec>,
    pub values: std::collections::BTreeMap<String, SettingValue>,
}

/// The one big object overlays render from. Sent whenever anything changes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PartySnapshot {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub presence: Vec<PlayerPresence>,
    pub players: Vec<Player>,
    pub seats: Vec<Seat>,
    pub playlist: PlaylistSnapshot,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_session: Option<SessionInfo>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub warm_session: Option<SessionInfo>,
    /// Games already played tonight, oldest first.
    pub history: Vec<GameId>,
    pub vote: VoteSnapshot,
    /// Whether the party overlay is up. Opening it pauses the active game;
    /// server-authoritative so every screen agrees.
    #[serde(default)]
    pub overlay_open: bool,
    /// The game shelf: every title the daemon knows, with cover art metadata.
    #[serde(default)]
    pub library: Vec<GameMeta>,
    /// Titles whose process is currently connected (playable right now).
    #[serde(default)]
    pub connected_games: Vec<GameId>,
    /// The game the daemon intends to have warm next, even before a session
    /// for it exists — while its process is still launching, say.
    ///
    /// Without this a screen can only see `warm_session`, so "still starting"
    /// and "nothing to play" look identical, and guessing from the playlist
    /// gets it wrong: the obvious guess is the first entry, which may be the
    /// game that's already running.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub warming: Option<PlaylistEntry>,
    /// Match settings per game: what each title lets the party tweak, and
    /// the current values. Only games that declared settings appear.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub settings: Vec<GameSettings>,
    /// Games arriving in the background right now, most interesting first
    /// (whatever is actually downloading leads). Empty once everything the
    /// party might want is on disk.
    ///
    /// Separate from `library`: these aren't playable yet, and showing them
    /// as shelf entries would offer the party something it can't have.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub installs: Vec<InstallStatus>,
    /// What the host has on in the background, if anything.
    ///
    /// `None` is the normal case — most nights nobody has music running, and
    /// a lobby that shows an empty music card on those nights is worse than
    /// one that shows none at all. Screens render this only when it's `Some`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub now_playing: Option<NowPlaying>,
}

// ---------------------------------------------------------------------------
// Voting
// ---------------------------------------------------------------------------

/// End-of-game options players stand on with their avatars.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VoteOption {
    Replay,
    Skip,
    NextGame,
    Quit,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct VoteSnapshot {
    /// Whether the party is currently being asked to choose.
    ///
    /// Without this, a screen cannot tell "waiting for you to vote" from
    /// "nothing happening": after a game finishes the night stops until the
    /// seated players pick, and a lobby with no way to say so just looks
    /// stuck.
    #[serde(default)]
    pub open: bool,
    /// Which option each player currently stands on.
    pub positions: Vec<(PlayerId, VoteOption)>,
    /// Set once consensus is reached; cleared when the next vote opens.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub decided: Option<VoteOption>,
}

// ---------------------------------------------------------------------------
// Messages: anything → daemon
// ---------------------------------------------------------------------------

/// The role a connection announces in its `hello`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    /// A game process (via an SDK). Receives session lifecycle commands.
    Game,
    /// An overlay / controller UI. Receives party snapshots, sends commands.
    Overlay,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientMessage {
    /// Opt into presence and live roster notifications for this prepared session.
    Participation {
        session: SessionId,
        instant_join: bool,
    },
    /// Meaningful human input (deadzone filtered, at most once a second per device).
    /// Games must supply their active session. Overlays omit it.
    ControllerInput {
        #[serde(default)]
        session: Option<SessionId>,
        controller: String,
    },

    /// Must be the first message on every connection.
    Hello {
        role: Role,
        /// For `Role::Game`: which title this process runs.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        game: Option<GameId>,
        /// The launch token from `GAMENIGHT_TOKEN`. Required when the daemon
        /// launched this process; omitted for manually started ones.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        token: Option<String>,
    },

    // -- overlay commands ---------------------------------------------------
    /// Walk in, grab a controller, press A. First free seat is yours — or ask
    /// for a specific one with `seat` (falls back to the first free seat if
    /// it's taken).
    JoinParty {
        name: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        seat: Option<u8>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        color: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        avatar: Option<String>,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        library: Vec<GameId>,
    },
    LeaveParty {
        player_id: PlayerId,
    },
    /// Change how a seated player's name reads everywhere (overlay, games
    /// that show `players[].name`).
    RenamePlayer {
        player_id: PlayerId,
        name: String,
    },
    /// Change a player's accent-color hint (see [`Player::color`]).
    SetPlayerSkinColor {
        player_id: PlayerId,
        skin_color: String,
    },
    SetPlayerColor {
        player_id: PlayerId,
        color: String,
    },
    /// Update a player's custom character pixel art avatar.
    SetPlayerAvatar {
        player_id: PlayerId,
        avatar: String,
    },
    AssignSeat {
        seat: u8,
        occupant: SeatOccupant,
    },
    /// Two people trade controllers: swap whoever sits in these two seats.
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
        expected: PlaylistSnapshot,
        from: usize,
        to: usize,
    },
    /// Remove one occurrence only, guarded against concurrent playlist edits.
    RemovePlaylistEntry {
        expected: PlaylistSnapshot,
        index: usize,
    },
    /// Skip to the warm session right now, no vote.
    Next,
    /// Make this game the next one up: it starts warming immediately
    /// (inserted into the playlist after the current entry if needed).
    PlayNext {
        game: GameId,
    },
    Pause,
    Resume,
    /// The party overlay came up: the active game pauses.
    OpenOverlay,
    /// The overlay went away: resume, if it was the overlay that paused.
    CloseOverlay,
    /// A player moves their avatar onto an option.
    Vote {
        player_id: PlayerId,
        option: VoteOption,
    },
    /// Pause, resume or skip the host's background music (see
    /// [`NowPlaying`]). Ignored when nothing is playing — there is nothing
    /// for the daemon to talk to.
    MediaControl {
        action: MediaAction,
    },
    /// Change a match setting. `game` defaults to the active game, so
    /// "disable items" mid-match needs no lookup. The daemon validates the
    /// value against the declared spec and pushes the change to the game.
    SetSetting {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        game: Option<GameId>,
        key: String,
        value: SettingValue,
    },

    // -- game (SDK) messages ------------------------------------------------
    /// Assets loaded, controllers mapped — the session can start instantly.
    Ready {
        session: SessionId,
    },
    /// The match is over; the daemon opens the vote / starts the transition.
    Finished {
        session: SessionId,
    },
    /// Optional: how far along warming is, so screens can show something
    /// truthful while the party waits. Send as often as is useful; the
    /// daemon keeps the latest. A game that loads instantly need never send
    /// this — "loading" without a number is still a legitimate state.
    Progress {
        session: SessionId,
        /// Whole percent, 0 to 100. Clamped by the daemon.
        percent: u8,
        /// Optional human-readable step ("generating arena").
        #[serde(default, skip_serializing_if = "Option::is_none")]
        label: Option<String>,
    },
    /// "Get me back to the party." Sent by a game when the player asks for
    /// the lobby (a Back button, Backspace...). The daemon pauses this
    /// session and gives the lobby the screen.
    ///
    /// Games are not allowed to drive the party in general — this is the one
    /// thing they may ask for, because a player stuck inside a game with no
    /// way out is the one failure the party cannot recover from themselves.
    RequestOverlay,
    /// "Somebody just asked for me." Sent by a game when a player reaches for
    /// it directly rather than through the party — on the desktop that means
    /// Cmd+Tab, a Dock click, a click on the window.
    ///
    /// The pair to `request_overlay`, and the same bargain: the game reports
    /// what the human did, the daemon decides what it means. Warm session ->
    /// start it. Paused active session -> resume it. Anything else -> nothing
    /// happens, and no harm done.
    ///
    /// Focus is the one thing the party can always express and GameNight
    /// cannot override — the window server has the final say. Taking it as a
    /// statement of intent turns that from a fight into an instruction: the
    /// game the party switched to is, by definition, the game they want.
    RequestStart,
    /// Declare the match settings this game exposes. Send once after
    /// `welcome` (and again after every reconnect). Replaces any previous
    /// declaration; values the party already changed persist where they are
    /// still valid under the new specs.
    DeclareSettings {
        settings: Vec<SettingSpec>,
    },
}

// ---------------------------------------------------------------------------
// Messages: daemon → anything
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerMessage {
    /// Full authoritative roster/presence for an opted-in session. Apply without
    /// resetting the match. Unknown fields/messages remain optional for old games.
    PartyUpdated {
        session: SessionId,
        seats: Vec<Seat>,
        players: Vec<Player>,
        presence: Vec<PlayerPresence>,
    },

    /// Reply to `hello`.
    Welcome {
        protocol_version: u32,
        party: PartySnapshot,
    },
    /// Broadcast to overlays whenever party state changes.
    PartyState {
        party: PartySnapshot,
    },

    // -- session lifecycle, sent to games -----------------------------------
    /// Warm up: load assets, map the given seats, then reply `ready`.
    Prepare {
        session: SessionId,
        game: GameId,
        seats: Vec<Seat>,
        players: Vec<Player>,
    },
    /// Become the active game *now*. Sent only after `ready`.
    Start {
        session: SessionId,
    },
    Pause {
        session: SessionId,
    },
    Resume {
        session: SessionId,
    },
    /// Tear everything down; the session id will never be used again.
    Dispose {
        session: SessionId,
    },
    /// A match setting changed; sent to the game that declared it. Apply it
    /// live if a match is running, otherwise from the next match. Also sent
    /// after `declare_settings` for every value the party had already
    /// changed from its default (reconnect re-hydration).
    SettingChanged {
        game: GameId,
        key: String,
        value: SettingValue,
    },

    /// Sent to the persistent lobby game specifically (see
    /// `GameNight::set_lobby_game`) — `active: false` the moment some other
    /// game actually starts, so the lobby can mute itself and step out of
    /// the way; `true` once the party's back with nothing else running. Not
    /// session-scoped: the lobby never has a tracked session of its own to
    /// hang this off of.
    LobbyFocus {
        active: bool,
    },

    /// Something was rejected. Informational; connections stay open.
    Error {
        message: String,
    },
}

impl ServerMessage {
    pub fn to_json(&self) -> String {
        serde_json::to_string(self).expect("protocol types always serialize")
    }
}

impl ClientMessage {
    pub fn to_json(&self) -> String {
        serde_json::to_string(self).expect("protocol types always serialize")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_client_message() {
        let msg = ClientMessage::Hello {
            role: Role::Game,
            game: Some(GameId::new("towerfall")),
            token: None,
        };
        let json = msg.to_json();
        assert!(json.contains("\"type\":\"hello\""));
        let back: ClientMessage = serde_json::from_str(&json).unwrap();
        assert_eq!(back, msg);
    }

    #[test]
    fn round_trip_server_message() {
        let msg = ServerMessage::Prepare {
            session: SessionId::new(),
            game: GameId::new("duck-game"),
            seats: vec![Seat {
                index: 0,
                occupant: SeatOccupant::Ai,
                controller: None,
            }],
            players: vec![],
        };
        let back: ServerMessage = serde_json::from_str(&msg.to_json()).unwrap();
        assert_eq!(back, msg);
    }

    #[test]
    fn unknown_fields_are_ignored() {
        let json = r#"{"type":"next","from_a_newer_client":true}"#;
        let msg: ClientMessage = serde_json::from_str(json).unwrap();
        assert_eq!(msg, ClientMessage::Next);
    }

    #[test]
    fn setting_specs_are_flat_on_the_wire() {
        let spec = SettingSpec {
            key: "stock".into(),
            label: "Stock count".into(),
            description: Some("Lives per player.".into()),
            kind: SettingKind::Number {
                default: 3,
                min: 1,
                max: 99,
            },
        };
        let json = serde_json::to_string(&spec).unwrap();
        // Flattened: no nested "kind" object, values are plain scalars.
        assert!(json.contains("\"kind\":\"number\""));
        assert!(json.contains("\"default\":3"));
        let back: SettingSpec = serde_json::from_str(&json).unwrap();
        assert_eq!(back, spec);
    }

    #[test]
    fn setting_values_are_plain_scalars() {
        let msg = ClientMessage::SetSetting {
            game: None,
            key: "items".into(),
            value: SettingValue::Toggle(false),
        };
        assert!(msg.to_json().contains("\"value\":false"));
        for (json, want) in [
            ("false", SettingValue::Toggle(false)),
            ("42", SettingValue::Number(42)),
            ("\"volcano\"", SettingValue::Choice("volcano".into())),
        ] {
            assert_eq!(serde_json::from_str::<SettingValue>(json).unwrap(), want);
        }
    }

    #[test]
    fn setting_validation_speaks_human() {
        let stock = SettingKind::Number {
            default: 3,
            min: 1,
            max: 99,
        };
        assert!(stock.validate(&SettingValue::Number(5)).is_ok());
        let err = stock.validate(&SettingValue::Number(500)).unwrap_err();
        assert!(err.contains("between 1 and 99"), "{err}");
        let err = stock.validate(&SettingValue::Toggle(true)).unwrap_err();
        assert!(err.contains("expected an integer"), "{err}");

        let arena = SettingKind::Choice {
            default: "meadow".into(),
            options: vec!["meadow".into(), "volcano".into()],
        };
        let err = arena
            .validate(&SettingValue::Choice("moon".into()))
            .unwrap_err();
        assert!(err.contains("meadow, volcano"), "{err}");
    }

    #[test]
    fn seat_occupant_player_id() {
        let p = PlayerId::new();
        assert_eq!(SeatOccupant::Local { player_id: p }.player_id(), Some(p));
        assert_eq!(SeatOccupant::Ai.player_id(), None);
        assert!(SeatOccupant::Empty.is_empty());
    }
}

#[cfg(test)]
mod addr_tests {
    use super::*;

    /// Whatever we detect must be something another device could dial. The
    /// bug this guards against is a join URL that says `127.0.0.1`, which on
    /// a phone resolves to the phone and silently fails.
    #[test]
    fn lan_ip_is_never_loopback_or_unspecified() {
        if let Some(ip) = lan_ip() {
            assert!(!ip.is_loopback(), "{ip} is loopback, phones can't reach it");
            assert!(!ip.is_unspecified(), "{ip} is unspecified");
        }
        // `None` is legitimate (no network at all) and callers fall back.
    }

    /// The base URL must be well-formed and carry the web port, whether or
    /// not a LAN address was found.
    #[test]
    fn web_base_url_is_well_formed() {
        let url = web_base_url();
        assert!(url.starts_with("http://"), "got {url}");
        assert!(
            url.ends_with(&format!(":{DEFAULT_WEB_PORT}")),
            "{url} must carry the web port"
        );
        assert!(!url.ends_with('/'), "{url} must not have a trailing slash");
    }

    /// When there is a LAN address, the URL has to actually use it rather
    /// than quietly falling back to loopback.
    #[test]
    fn web_base_url_prefers_the_lan_address() {
        if let Some(ip) = lan_ip() {
            assert_eq!(url_host(&web_base_url()), ip.to_string());
        }
    }

    fn url_host(url: &str) -> String {
        url.trim_start_matches("http://")
            .rsplit_once(':')
            .map(|(host, _)| host.to_string())
            .unwrap_or_default()
    }
}
