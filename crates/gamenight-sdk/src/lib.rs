//! GameNight SDK for games written in Rust.
//!
//! The integration contract is deliberately tiny — the goal is a working
//! integration in under an hour:
//!
//! 1. [`GameNight::connect`] with your game id.
//! 2. Loop on [`GameNight::next_event`].
//! 3. On [`GameEvent::Prepare`]: load assets, map the given seats, then call
//!    [`GameNight::ready`]. Do **not** show anything yet.
//! 4. On [`GameEvent::Start`]: you are live — start the match instantly.
//! 5. When the match ends, call [`GameNight::finished`] and keep rendering
//!    until [`GameEvent::Dispose`], then tear the session down.
//!
//! Everything else (party membership, playlists, voting, transitions) is the
//! daemon's problem, not yours.
//!
//! ```no_run
//! # use gamenight_sdk::{GameNight, GameEvent};
//! # async fn run() -> Result<(), gamenight_sdk::SdkError> {
//! let mut gn = GameNight::connect("my-game", None).await?;
//! while let Some(event) = gn.next_event().await? {
//!     match event {
//!         GameEvent::Prepare { session, seats, .. } => {
//!             // load level, bind inputs to `seats`...
//!             gn.ready(session).await?;
//!         }
//!         GameEvent::Start { .. } => { /* go! */ }
//!         GameEvent::Dispose { .. } => break,
//!         _ => {}
//!     }
//! }
//! # Ok(()) }
//! ```

use futures_util::{SinkExt, StreamExt};
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};
use tracing::debug;

use gamenight_protocol::{
    ClientMessage, GameId, PartySnapshot, Player, Role, Seat, ServerMessage, SessionId,
    SettingSpec, SettingValue, DEFAULT_ADDR, ENV_ADDR, ENV_GAMENIGHT, ENV_GAME_ID, ENV_TOKEN,
    PROTOCOL_VERSION,
};

#[derive(Debug, thiserror::Error)]
pub enum SdkError {
    #[error("websocket error: {0}")]
    WebSocket(Box<tokio_tungstenite::tungstenite::Error>),
    #[error("protocol error: {0}")]
    Protocol(String),
    #[error("daemon rejected: {0}")]
    Rejected(String),
}

impl From<tokio_tungstenite::tungstenite::Error> for SdkError {
    fn from(e: tokio_tungstenite::tungstenite::Error) -> Self {
        SdkError::WebSocket(Box::new(e))
    }
}

/// Session lifecycle events, in the order a game will see them.
#[derive(Debug, Clone, PartialEq)]
pub enum GameEvent {
    /// Apply live presence and (when opted in) roster changes without restarting.
    PartyUpdated {
        session: SessionId,
        seats: Vec<Seat>,
        players: Vec<Player>,
        presence: Vec<gamenight_protocol::PlayerPresence>,
    },

    /// Warm up: load everything for these seats, then call [`GameNight::ready`].
    Prepare {
        session: SessionId,
        seats: Vec<Seat>,
        players: Vec<Player>,
    },
    /// The transition landed on you. Start the match *now*.
    Start {
        session: SessionId,
    },
    Pause {
        session: SessionId,
    },
    Resume {
        session: SessionId,
    },
    /// Tear the session down. A new `Prepare` may follow on the same connection.
    Dispose {
        session: SessionId,
    },
    /// The party changed one of the settings you declared with
    /// [`GameNight::declare_settings`]. Apply it live if a match is running,
    /// otherwise from the next match.
    SettingChanged {
        key: String,
        value: SettingValue,
    },
    /// Only ever sent to the process registered as the persistent lobby
    /// (`GAMENIGHT_GAME_ID` matching what the daemon was told via
    /// `set_lobby_game`) — `active: false` the moment some other game
    /// actually starts, so the lobby can mute itself and step out of the
    /// way; `true` once the party's back with nothing else running.
    LobbyFocus {
        active: bool,
    },
}

/// A live connection from a game process to the GameNight daemon.
pub struct GameNight {
    ws: WebSocketStream<MaybeTlsStream<TcpStream>>,
    party: PartySnapshot,
}

impl GameNight {
    /// Was this process launched by a GameNight daemon? When true,
    /// [`GameNight::connect_from_env`] has everything it needs.
    pub fn launched_by_daemon() -> bool {
        std::env::var(ENV_GAMENIGHT).is_ok_and(|v| v == "1")
    }

    /// Connect using the environment the daemon set at launch
    /// (`GAMENIGHT_ADDR`, `GAMENIGHT_GAME_ID`, `GAMENIGHT_TOKEN`). This is
    /// what a game calls at startup when [`Self::launched_by_daemon`]; the
    /// same binary runs standalone otherwise.
    pub async fn connect_from_env() -> Result<Self, SdkError> {
        let game_id = std::env::var(ENV_GAME_ID)
            .map_err(|_| SdkError::Protocol(format!("{ENV_GAME_ID} is not set")))?;
        Self::connect(game_id, None).await
    }

    /// Connect and register as the process serving `game_id`.
    /// `addr` falls back to `GAMENIGHT_ADDR`, then the standard local
    /// address. The launch token, if present in the environment, is included
    /// automatically.
    pub async fn connect(game_id: impl Into<String>, addr: Option<&str>) -> Result<Self, SdkError> {
        let env_addr = std::env::var(ENV_ADDR).ok();
        let url = format!(
            "ws://{}",
            addr.or(env_addr.as_deref()).unwrap_or(DEFAULT_ADDR)
        );
        let (mut ws, _) = tokio_tungstenite::connect_async(&url).await?;
        let hello = ClientMessage::Hello {
            role: Role::Game,
            game: Some(GameId::new(game_id)),
            token: std::env::var(ENV_TOKEN).ok(),
        };
        ws.send(Message::Text(hello.to_json())).await?;

        // The daemon answers hello with welcome (or an error).
        let party = loop {
            match ws.next().await {
                Some(Ok(Message::Text(text))) => match parse_server(&text)? {
                    ServerMessage::Welcome {
                        protocol_version,
                        party,
                    } => {
                        if protocol_version != PROTOCOL_VERSION {
                            return Err(SdkError::Protocol(format!(
                                "daemon speaks protocol v{protocol_version}, sdk speaks v{PROTOCOL_VERSION}"
                            )));
                        }
                        break party;
                    }
                    ServerMessage::Error { message } => return Err(SdkError::Rejected(message)),
                    other => {
                        debug!(?other, "ignoring pre-welcome message");
                    }
                },
                Some(Ok(_)) => continue,
                Some(Err(e)) => return Err(e.into()),
                None => return Err(SdkError::Protocol("connection closed during hello".into())),
            }
        };
        Ok(Self { ws, party })
    }

    /// The party as of the last message from the daemon.
    pub fn party(&self) -> &PartySnapshot {
        &self.party
    }

    /// Wait for the next lifecycle event. `Ok(None)` means the daemon went away.
    pub async fn next_event(&mut self) -> Result<Option<GameEvent>, SdkError> {
        loop {
            match self.ws.next().await {
                Some(Ok(Message::Text(text))) => {
                    let event = match parse_server(&text)? {
                        ServerMessage::PartyUpdated {
                            session,
                            seats,
                            players,
                            presence,
                        } => {
                            self.party.seats = seats.clone();
                            self.party.players = players.clone();
                            self.party.presence = presence.clone();
                            GameEvent::PartyUpdated {
                                session,
                                seats,
                                players,
                                presence,
                            }
                        }
                        ServerMessage::Prepare {
                            session,
                            seats,
                            players,
                            ..
                        } => GameEvent::Prepare {
                            session,
                            seats,
                            players,
                        },
                        ServerMessage::Start { session } => GameEvent::Start { session },
                        ServerMessage::Pause { session } => GameEvent::Pause { session },
                        ServerMessage::Resume { session } => GameEvent::Resume { session },
                        ServerMessage::Dispose { session } => GameEvent::Dispose { session },
                        ServerMessage::SettingChanged { key, value, .. } => {
                            GameEvent::SettingChanged { key, value }
                        }
                        ServerMessage::LobbyFocus { active } => GameEvent::LobbyFocus { active },
                        ServerMessage::PartyState { party } => {
                            self.party = party;
                            continue;
                        }
                        ServerMessage::Welcome { party, .. } => {
                            self.party = party;
                            continue;
                        }
                        ServerMessage::Error { message } => {
                            return Err(SdkError::Rejected(message))
                        }
                    };
                    return Ok(Some(event));
                }
                Some(Ok(Message::Ping(p))) => {
                    let _ = self.ws.send(Message::Pong(p)).await;
                }
                Some(Ok(Message::Close(_))) | None => return Ok(None),
                Some(Ok(_)) => continue,
                Some(Err(e)) => return Err(e.into()),
            }
        }
    }

    /// Opt into AFK notifications; set instant_join only if the game can insert
    /// players into the current round. Call after Prepare and before ready.
    pub async fn participation(
        &mut self,
        session: SessionId,
        instant_join: bool,
    ) -> Result<(), SdkError> {
        self.send(&ClientMessage::Participation {
            session,
            instant_join,
        })
        .await
    }

    /// Report real human input, including unassigned devices. Apply deadzones
    /// before reporting and throttle held input to once per second per device.
    pub async fn controller_input(
        &mut self,
        session: SessionId,
        controller: String,
    ) -> Result<(), SdkError> {
        self.send(&ClientMessage::ControllerInput {
            session: Some(session),
            controller,
        })
        .await
    }

    /// Assets loaded, controllers mapped: the session can start instantly.
    pub async fn ready(&mut self, session: SessionId) -> Result<(), SdkError> {
        self.send(&ClientMessage::Ready { session }).await
    }

    /// The match is over. The daemon takes it from here (vote / transition).
    pub async fn finished(&mut self, session: SessionId) -> Result<(), SdkError> {
        self.send(&ClientMessage::Finished { session }).await
    }

    /// Optional: say how far along warming is (0-100), so the lobby can show
    /// the party something truthful while they wait instead of an unchanging
    /// "loading". Send as often as is useful; the daemon keeps the latest.
    /// A game that loads instantly never needs to call this.
    pub async fn progress(
        &mut self,
        session: SessionId,
        percent: u8,
        label: Option<String>,
    ) -> Result<(), SdkError> {
        self.send(&ClientMessage::Progress {
            session,
            percent,
            label,
        })
        .await
    }

    /// A player asked to get back to the party (a Back button, Backspace…).
    /// Pauses this session and puts the lobby back on screen.
    ///
    /// The one party command a game may send — see `ClientMessage`.
    pub async fn request_overlay(&mut self) -> Result<(), SdkError> {
        self.send(&ClientMessage::RequestOverlay).await
    }

    /// Declare the match settings the party may change (items on/off, stock
    /// count, arena…). Call once after connecting. The daemon validates
    /// every write and delivers changes as [`GameEvent::SettingChanged`];
    /// values the party already picked survive reconnects and are replayed
    /// right after this call.
    pub async fn declare_settings(&mut self, settings: Vec<SettingSpec>) -> Result<(), SdkError> {
        self.send(&ClientMessage::DeclareSettings { settings })
            .await
    }

    async fn send(&mut self, msg: &ClientMessage) -> Result<(), SdkError> {
        self.ws.send(Message::Text(msg.to_json())).await?;
        Ok(())
    }
}

fn parse_server(text: &str) -> Result<ServerMessage, SdkError> {
    serde_json::from_str(text).map_err(|e| SdkError::Protocol(format!("bad server message: {e}")))
}
