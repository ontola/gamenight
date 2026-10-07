//! Phone screens for games ("companions").
//!
//! A game declares a small web page with `declare_companion`. While that game
//! is the active session, a seated player's phone opens the page from here
//! (`/play/<game>/<entry>`) and talks to the game over one WebSocket
//! (`/api/companion/ws`). This module keeps a single overlay connection to the
//! daemon and routes `companion_message` traffic between the game and the
//! phone of the player it is for. The phone never names its own player: it
//! proves who it is with its profile id, which this server already bound to a
//! party member when the phone signed in.
use crate::SharedState;
use axum::{
    extract::{
        ws::{Message as WsMessage, WebSocket, WebSocketUpgrade},
        Path, Query, State,
    },
    http::{header, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use futures_util::{SinkExt, StreamExt};
use gamenight_protocol::{
    ClientMessage, CompanionScreen, GameId, PartySnapshot, PlayerId, Role, ServerMessage,
};
use serde::Deserialize;
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;

/// Largest message a phone may send. Phone screens exchange taps and small
/// state, never files.
const MAX_PHONE_MESSAGE: usize = 16 * 1024;

#[derive(Clone, Default)]
pub struct Hub(Arc<Mutex<Inner>>);

#[derive(Default)]
struct Inner {
    party: Option<PartySnapshot>,
    daemon: Option<mpsc::UnboundedSender<String>>,
    phones: HashMap<u64, Phone>,
    next_phone: u64,
}

struct Phone {
    game: GameId,
    player: PlayerId,
    tx: mpsc::UnboundedSender<String>,
}

impl Hub {
    /// The screen of the game the party is playing right now, if it has one.
    pub fn active(&self) -> Option<(CompanionScreen, String)> {
        let inner = self.0.lock().unwrap();
        let party = inner.party.as_ref()?;
        let game = &party.active_session.as_ref()?.game;
        let screen = party.companions.iter().find(|c| &c.game == game)?.clone();
        let title = party
            .library
            .iter()
            .find(|meta| &meta.id == game)
            .map(|meta| meta.title.clone())
            .unwrap_or_else(|| game.0.clone());
        Some((screen, title))
    }

    fn screen(&self, game: &GameId) -> Option<CompanionScreen> {
        let inner = self.0.lock().unwrap();
        inner
            .party
            .as_ref()?
            .companions
            .iter()
            .find(|c| &c.game == game)
            .cloned()
    }

    fn to_daemon(&self, message: ClientMessage) {
        if let Some(tx) = &self.0.lock().unwrap().daemon {
            let _ = tx.send(message.to_json());
        }
    }

    /// Keep one overlay connection to the daemon for as long as the server
    /// runs, reconnecting when the daemon restarts.
    pub async fn run(self, addr: String) {
        loop {
            if let Err(error) = self.session(&addr).await {
                tracing::debug!(%error, "phone screen relay disconnected");
            }
            {
                let mut inner = self.0.lock().unwrap();
                inner.daemon = None;
                inner.party = None;
            }
            tokio::time::sleep(Duration::from_secs(1)).await;
        }
    }

    async fn session(&self, addr: &str) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
        let (ws, _) = tokio_tungstenite::connect_async(format!("ws://{addr}")).await?;
        let (mut sink, mut stream) = ws.split();
        sink.send(Message::Text(
            ClientMessage::Hello {
                role: Role::Overlay,
                game: None,
                token: None,
            }
            .to_json(),
        ))
        .await?;
        let (tx, mut rx) = mpsc::unbounded_channel::<String>();
        let writer = tokio::spawn(async move {
            while let Some(text) = rx.recv().await {
                if sink.send(Message::Text(text)).await.is_err() {
                    break;
                }
            }
        });
        self.0.lock().unwrap().daemon = Some(tx);
        while let Some(message) = stream.next().await {
            let Message::Text(text) = message? else {
                continue;
            };
            match serde_json::from_str::<ServerMessage>(&text) {
                Ok(ServerMessage::Welcome { party, .. } | ServerMessage::PartyState { party }) => {
                    self.update_party(party)
                }
                Ok(ServerMessage::CompanionMessage {
                    game,
                    player_id,
                    data,
                }) => self.deliver(&game, player_id, &data),
                _ => {}
            }
        }
        writer.abort();
        Ok(())
    }

    /// Track declared screens. Phones of a game that just (re)declared its
    /// screen are announced again, so a restarted game learns who is
    /// watching; phones of a game that went away are closed.
    fn update_party(&self, party: PartySnapshot) {
        let mut inner = self.0.lock().unwrap();
        let before: Vec<GameId> = inner
            .party
            .as_ref()
            .map(|p| p.companions.iter().map(|c| c.game.clone()).collect())
            .unwrap_or_default();
        let now: Vec<GameId> = party.companions.iter().map(|c| c.game.clone()).collect();
        inner.phones.retain(|_, phone| now.contains(&phone.game));
        if let Some(daemon) = &inner.daemon {
            for phone in inner.phones.values() {
                if !before.contains(&phone.game) {
                    let _ = daemon.send(
                        ClientMessage::CompanionPresence {
                            game: phone.game.clone(),
                            player_id: phone.player,
                            connected: true,
                        }
                        .to_json(),
                    );
                }
            }
        }
        inner.party = Some(party);
    }

    fn deliver(&self, game: &GameId, player: Option<PlayerId>, data: &serde_json::Value) {
        let text = data.to_string();
        let inner = self.0.lock().unwrap();
        for phone in inner.phones.values() {
            if &phone.game == game && player.is_none_or(|p| p == phone.player) {
                let _ = phone.tx.send(text.clone());
            }
        }
    }

    fn add_phone(&self, game: GameId, player: PlayerId) -> (u64, mpsc::UnboundedReceiver<String>) {
        let (tx, rx) = mpsc::unbounded_channel();
        let id = {
            let mut inner = self.0.lock().unwrap();
            let id = inner.next_phone;
            inner.next_phone += 1;
            inner.phones.insert(
                id,
                Phone {
                    game: game.clone(),
                    player,
                    tx,
                },
            );
            id
        };
        self.to_daemon(ClientMessage::CompanionPresence {
            game,
            player_id: player,
            connected: true,
        });
        (id, rx)
    }

    fn remove_phone(&self, id: u64) {
        let phone = self.0.lock().unwrap().phones.remove(&id);
        if let Some(phone) = phone {
            self.to_daemon(ClientMessage::CompanionPresence {
                game: phone.game,
                player_id: phone.player,
                connected: false,
            });
        }
    }
}

#[derive(Deserialize)]
pub struct ProfileQuery {
    profile: String,
    #[serde(default)]
    game: Option<String>,
}

fn hub_and_player(state: &SharedState, profile: &str) -> (Hub, Option<PlayerId>) {
    let state = state.lock().unwrap();
    (
        state.companions.clone(),
        state.bindings.get(profile).copied(),
    )
}

/// `GET /api/companion?profile=…`: the phone screen this player should see
/// now, or `{"game": null}` when the current game has none.
pub async fn current(
    State(state): State<SharedState>,
    Query(query): Query<ProfileQuery>,
) -> Json<serde_json::Value> {
    let (hub, player) = hub_and_player(&state, &query.profile);
    match (player, hub.active()) {
        (Some(player), Some((screen, title))) => {
            let profile = encode(&query.profile);
            let url = screen.entry.as_ref().map(|entry| {
                format!(
                    "/play/{}/{entry}?profile={profile}&game={}",
                    screen.game, screen.game
                )
            });
            // A download inside the game's folder is served from here, so
            // the GameNight PC installs the app over the LAN.
            let app = screen.app.map(|app| {
                let download = app.download.map(|d| {
                    if d.starts_with("https://") {
                        d
                    } else {
                        format!("/play/{}/{d}", screen.game)
                    }
                });
                serde_json::json!({"name": app.name, "android": app.android, "download": download})
            });
            Json(serde_json::json!({
                "game": screen.game,
                "title": title,
                "player_id": player,
                "url": url,
                "app": app,
            }))
        }
        _ => Json(serde_json::json!({"game": null, "linked": player.is_some()})),
    }
}

fn encode(text: &str) -> String {
    text.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                (b as char).to_string()
            }
            _ => format!("%{b:02X}"),
        })
        .collect()
}

/// `GET /play/<game>/<path>`: a file of a declared phone screen.
pub async fn file(
    State(state): State<SharedState>,
    Path((game, path)): Path<(String, String)>,
) -> Response {
    let hub = state.lock().unwrap().companions.clone();
    let Some(root) = hub.screen(&GameId::new(game)).and_then(|s| s.root) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let Some(file) = resolve(std::path::Path::new(&root), &path) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    match tokio::fs::read(&file).await {
        Ok(body) => (
            [
                (header::CONTENT_TYPE, content_type(&file)),
                (header::CACHE_CONTROL, "no-store"),
            ],
            body,
        )
            .into_response(),
        Err(_) => StatusCode::NOT_FOUND.into_response(),
    }
}

/// A file under `root`, refusing anything that escapes it (`..`, absolute
/// paths, symlinks pointing outside).
fn resolve(root: &std::path::Path, path: &str) -> Option<std::path::PathBuf> {
    let root = root.canonicalize().ok()?;
    let mut file = root.join(path.trim_start_matches('/'));
    if file.is_dir() {
        file = file.join("index.html");
    }
    let file = file.canonicalize().ok()?;
    (file.starts_with(&root) && file.is_file()).then_some(file)
}

fn content_type(path: &std::path::Path) -> &'static str {
    match path.extension().and_then(|e| e.to_str()).unwrap_or("") {
        "html" | "htm" => "text/html; charset=utf-8",
        "js" | "mjs" => "text/javascript; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "json" => "application/json",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "webp" => "image/webp",
        "woff2" => "font/woff2",
        "apk" => "application/vnd.android.package-archive",
        "wav" => "audio/wav",
        "ogg" => "audio/ogg",
        "mp3" => "audio/mpeg",
        _ => "application/octet-stream",
    }
}

/// `GET /api/companion/ws?profile=…&game=…`: the phone's line to its game.
pub async fn socket(
    State(state): State<SharedState>,
    Query(query): Query<ProfileQuery>,
    upgrade: WebSocketUpgrade,
) -> Response {
    let (hub, player) = hub_and_player(&state, &query.profile);
    let Some(player) = player else {
        return (StatusCode::FORBIDDEN, "sign in to this GameNight first").into_response();
    };
    let Some(game) = query.game.map(GameId::new) else {
        return StatusCode::BAD_REQUEST.into_response();
    };
    if hub.screen(&game).is_none_or(|s| s.entry.is_none()) {
        return (StatusCode::NOT_FOUND, "this game has no phone screen").into_response();
    }
    upgrade
        .max_message_size(MAX_PHONE_MESSAGE)
        .on_upgrade(move |ws| relay(ws, hub, game, player))
}

async fn relay(ws: WebSocket, hub: Hub, game: GameId, player: PlayerId) {
    let (mut sink, mut stream) = ws.split();
    let (id, mut rx) = hub.add_phone(game.clone(), player);
    loop {
        tokio::select! {
            outgoing = rx.recv() => match outgoing {
                Some(text) => if sink.send(WsMessage::Text(text)).await.is_err() { break },
                // The game went away; the page reconnects when it is back.
                None => break,
            },
            incoming = stream.next() => match incoming {
                Some(Ok(WsMessage::Text(text))) => {
                    let Ok(data) = serde_json::from_str(&text) else { continue };
                    hub.to_daemon(ClientMessage::CompanionMessage {
                        game: Some(game.clone()),
                        player_id: Some(player),
                        data,
                    });
                }
                Some(Ok(WsMessage::Close(_))) | Some(Err(_)) | None => break,
                Some(Ok(_)) => {}
            },
        }
    }
    hub.remove_phone(id);
    let _ = sink.close().await;
}

/// `GET /assets/companion.js`: the few lines a phone screen needs.
pub async fn script() -> impl IntoResponse {
    (
        [
            (header::CONTENT_TYPE, "text/javascript; charset=utf-8"),
            (header::CACHE_CONTROL, "no-store"),
        ],
        include_str!("companion.js"),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn files_stay_inside_the_declared_root() {
        let dir = std::env::temp_dir().join(format!("gn-companion-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(dir.join("phone")).unwrap();
        std::fs::write(dir.join("phone/index.html"), "hi").unwrap();
        std::fs::write(dir.join("secret.txt"), "no").unwrap();
        let root = dir.join("phone");
        assert!(resolve(&root, "index.html").is_some());
        assert!(resolve(&root, "").is_some(), "a directory serves its index");
        assert!(resolve(&root, "../secret.txt").is_none());
        assert!(resolve(&root, "/etc/passwd").is_none());
        assert!(resolve(&root, "missing.js").is_none());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn messages_reach_only_the_addressed_phone() {
        let hub = Hub::default();
        let game = GameId::new("hexstead");
        let (alice, bob) = (PlayerId::new(), PlayerId::new());
        let (_, mut to_alice) = hub.add_phone(game.clone(), alice);
        let (_, mut to_bob) = hub.add_phone(game.clone(), bob);
        hub.deliver(&game, Some(alice), &serde_json::json!({"hand": 3}));
        assert_eq!(to_alice.try_recv().unwrap(), r#"{"hand":3}"#);
        assert!(to_bob.try_recv().is_err());
        hub.deliver(&game, None, &serde_json::json!("all"));
        assert!(to_alice.try_recv().is_ok() && to_bob.try_recv().is_ok());
        hub.deliver(&GameId::new("other"), None, &serde_json::json!("x"));
        assert!(to_alice.try_recv().is_err());
    }
}
