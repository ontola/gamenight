use axum::{
    extract::{Path, Query, State},
    http::{HeaderValue, StatusCode},
    response::{Html, IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
mod cloud;
mod dev_catalog;
mod dev_web;
mod playlist;
mod local_room;
use gamenight_protocol::{ClientMessage, PlayerId};
use qrcode::render::svg;
use qrcode::QrCode;
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Profile {
    pub id: String,
    pub username: String,
    #[serde(default = "default_skin_color")]
    pub skin_color: String,
    pub avatar: String, // 16x16 pixel matrix serialized or data URI
}

fn default_skin_color() -> String {
    "#f5e9be".into()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JoinSessionRequest {
    #[serde(default)]
    pub link_revision: u64,
    /// The player to apply this profile to, instead of adding a new one.
    ///
    /// Comes from the `?claim=<player_id>` on the QR floating above a
    /// character's head in the lobby: that body already exists and is
    /// already driven by someone's controller, so joining again would strand
    /// a second, bodiless party member (a controller-less player never
    /// spawns — see the lobby's `match_plugin_for_seats`). Claiming renames and
    /// recolors the character you walked up to instead.
    #[serde(default)]
    pub claim: Option<PlayerId>,
    /// The seat to apply this profile to, resolved to its occupant at the
    /// moment of the claim.
    ///
    /// Preferred over `claim`: seat indices are stable, whereas player ids
    /// are cleared whenever the lobby process restarts. A QR printed minutes
    /// ago still points at the right chair, where an id-bearing one would
    /// have quietly aimed at a deleted player.
    #[serde(default)]
    pub seat: Option<u8>,
}

pub struct ServerState {
    local_room: local_room::Room,
    cloud: Option<cloud::Bridge>,
    pub profiles: HashMap<String, Profile>,
    pub daemon_addr: String,
    /// Which party member each profile is currently signed in as.
    ///
    /// One device is one person, so one profile may hold at most one seat.
    /// Without this a phone could scan, walk to the next pad, scan again, and
    /// end up driving two characters with the same name and face — which is
    /// both confusing on the couch and a way to quietly take a seat away
    /// from someone who hasn't sat down yet.
    ///
    /// Server-side rather than in the phone's storage, because the check has
    /// to hold even if someone clears their browser or opens a second tab.
    #[doc(hidden)]
    pub bindings: HashMap<String, PlayerId>,
    pub link_revisions: HashMap<PlayerId, u64>,
}

impl ServerState {
    pub fn new(daemon_addr: String) -> Self {
        Self {
            local_room: local_room::Room::new(),
            cloud: None,
            profiles: HashMap::new(),
            daemon_addr,
            bindings: HashMap::new(),
            link_revisions: HashMap::new(),
        }
    }
}

pub type SharedState = Arc<Mutex<ServerState>>;

pub fn create_router(state: SharedState) -> Router {
    Router::new()
        .route("/api/dev-catalog/room", get(dev_catalog::status))
        .route("/api/dev-catalog/next", post(dev_catalog::next))
        .route(
            "/favicon.ico",
            get(|| async {
                (
                    [("content-type", "image/x-icon")],
                    include_bytes!("../../../web/favicon.ico").as_slice(),
                )
            }),
        )
        .route(
            "/apple-touch-icon.png",
            get(|| async {
                (
                    [("content-type", "image/png")],
                    include_bytes!("../../../web/apple-touch-icon.png").as_slice(),
                )
            }),
        )
        .route("/studio", get(serve_studio))
        .route("/web/:asset", get(serve_web_asset))
        .route(
            "/web/fonts/ark-pixel-16px-latin.ttf",
            get(|| async {
                (
                    [("content-type", "font/ttf")],
                    include_bytes!("../../../web/fonts/ark-pixel-16px-latin.ttf").as_slice(),
                )
            }),
        )
        .route(
            "/assets/jsQR.js",
            get(|| async {
                (
                    [(axum::http::header::CONTENT_TYPE, "text/javascript")],
                    include_str!("../assets/jsQR.js"),
                )
            }),
        )
        .route(
            "/assets/qr-scanner.js",
            get(|| async {
                (
                    [(axum::http::header::CONTENT_TYPE, "text/javascript")],
                    include_str!("../assets/qr-scanner.js"),
                )
            }),
        )
        .route("/assets/characters/:theme", get(serve_character))
        .route("/mobile", get(serve_studio))
        .route("/session/:session_id", get(serve_studio))
        .route(
            "/api/playlist",
            get(playlist::get).post(playlist::move_entry),
        )
        .route("/api/player-links", get(player_links))
        .route("/api/local-room/join", post(local_room::join))
        .route("/api/local-room/cancel/:id", post(local_room::cancel))
        .route("/api/room-pickup/:pending/:player", post(room_pickup))
        .route("/api/player-links/:id/unlink", post(unlink_player))
        .route("/api/profiles", post(save_profile))
        .route("/api/profiles/:id", get(get_profile))
        .route("/api/profiles/:id/join", post(join_session))
        .route("/api/profiles/:id/session", get(profile_session))
        .route("/qr", get(serve_qr))
        .route("/qr/:session_id", get(serve_session_qr))
        .route("/", get(serve_studio))
        .layer(axum::middleware::from_fn(dev_web::assets))
        .with_state(state)
}

pub async fn run_server(
    addr: std::net::SocketAddr,
    state: SharedState,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    if let Some(bridge) = cloud::Bridge::configured() {
        state.lock().unwrap().cloud = Some(bridge.clone());
        tokio::spawn(bridge.run(state.clone()));
    }
    let app = create_router(state);
    let listener = tokio::net::TcpListener::bind(addr).await?;
    // Log the address a phone can actually use, not just the bind address —
    // `0.0.0.0` is not something anyone can type into a browser.
    tracing::info!(
        "🌐 GameNight Web Server & Studio bound to {addr}, reachable at {}",
        gamenight_protocol::web_base_url()
    );
    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<std::net::SocketAddr>(),
    )
    .await?;
    Ok(())
}

async fn profile_session(
    Path(id): Path<String>,
    State(state): State<SharedState>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    use futures_util::SinkExt;
    use gamenight_protocol::Role;
    let addr = state.lock().unwrap().daemon_addr.clone();
    tokio::time::timeout(daemon::REPLY_TIMEOUT * 2, async {
        let (mut ws, _) = tokio_tungstenite::connect_async(format!("ws://{addr}")).await.map_err(|_| StatusCode::BAD_GATEWAY)?;
        ws.send(tokio_tungstenite::tungstenite::Message::Text(ClientMessage::Hello { role: Role::Overlay, game: None, token: None }.to_json())).await.map_err(|_| StatusCode::BAD_GATEWAY)?;
        let party = daemon::read_welcome(&mut ws).await.map_err(StatusCode::from)?;
        let bound = state.lock().unwrap().bindings.get(&id).copied();
        let player = bound.and_then(|id| party.players.iter().find(|player| player.id == id));
        let seat = player.and_then(|player| party.seats.iter().find(|seat| seat.occupant.player_id() == Some(player.id))).map(|seat| seat.index);
        let title = |game: &gamenight_protocol::GameId| party.library.iter().find(|meta| &meta.id == game).map(|meta| meta.title.clone()).unwrap_or_else(|| game.0.clone());
        let current = party.active_session.as_ref().map(|session| serde_json::json!({"title": title(&session.game), "phase": session.phase}));
        let next = party.warm_session.as_ref().map(|session| title(&session.game)).or_else(|| party.warming.as_ref().map(|entry| entry.title.clone()));
        let local = state.lock().unwrap();
        Ok(Json(serde_json::json!({"linked": player.is_some(), "player_id":player.map(|p|p.id), "link_revision":player.and_then(|p|local.link_revisions.get(&p.id)).copied().unwrap_or(0), "waiting":local.local_room.waiting(&id), "player_name": player.map(|player| &player.name), "seat": seat, "players": party.players.len(), "current": current, "next": next})))
    }).await.map_err(|_| StatusCode::GATEWAY_TIMEOUT)?
}

async fn player_links(State(state): State<SharedState>) -> Json<serde_json::Value> {
    let state = state.lock().unwrap();
    Json(
        serde_json::json!({"linked": state.bindings.values().collect::<Vec<_>>(), "revisions": state.link_revisions,"room":state.cloud.as_ref().map(|b|b.waiting()).unwrap_or_else(||state.local_room.snapshot(&state.profiles)), "cloud":state.cloud.is_some(), "pairing_urls":state.cloud.as_ref().map(|b|b.pairing_urls()).unwrap_or_default()}),
    )
}

async fn room_pickup(
    axum::extract::ConnectInfo(peer): axum::extract::ConnectInfo<std::net::SocketAddr>,
    headers: axum::http::HeaderMap,
    Path((pending, player)): Path<(String, PlayerId)>,
    State(state): State<SharedState>,
) -> StatusCode {
    // Only the native lobby on this machine may complete a pickup. The custom
    // header also forces browser callers through an unsupported CORS preflight.
    if !peer.ip().is_loopback()
        || headers
            .get("x-gamenight-local-pickup")
            .and_then(|h| h.to_str().ok())
            != Some("1")
    {
        return StatusCode::FORBIDDEN;
    }
    let bridge = state.lock().unwrap().cloud.clone();
    match bridge {
        Some(b) => b.pickup(&state, &pending, player).await,
        None => local_room::pickup(&state, &pending, player).await,
    }
}

async fn unlink_player(Path(id): Path<PlayerId>, State(state): State<SharedState>) -> StatusCode {
    let addr = {
        let mut local = state.lock().unwrap();
        local.bindings.retain(|_, player| *player != id);
        *local.link_revisions.entry(id).or_default() += 1;
        local.daemon_addr.clone()
    };
    use futures_util::{SinkExt, StreamExt};
    let result = tokio::time::timeout(daemon::REPLY_TIMEOUT * 2, async {
        let (mut ws, _) = tokio_tungstenite::connect_async(format!("ws://{addr}"))
            .await
            .ok()?;
        let names = [
            "Rocket", "Panda", "Pickle", "Tiger", "Comet", "Disco", "Pixel", "Mango",
        ];
        let random = uuid::Uuid::new_v4();
        let mut index = random.as_bytes()[0] as usize % names.len();
        ws.send(tokio_tungstenite::tungstenite::Message::Text(
            ClientMessage::Hello {
                role: gamenight_protocol::Role::Overlay,
                game: None,
                token: None,
            }
            .to_json(),
        ))
        .await
        .ok()?;
        let party = read_welcome(&mut ws).await.ok()?;
        let player = party.players.iter().find(|p| p.id == id)?;
        if player.name == names[index] {
            index = (index + 1) % names.len();
        }
        let name = names[index].to_string();
        for message in [
            ClientMessage::RenamePlayer {
                player_id: id,
                name: name.clone(),
            },
            ClientMessage::SetPlayerAvatar {
                player_id: id,
                avatar: String::new(),
            },
            ClientMessage::SetPlayerSkinColor {
                player_id: id,
                skin_color: default_skin_color(),
            },
        ] {
            ws.send(tokio_tungstenite::tungstenite::Message::Text(
                message.to_json(),
            ))
            .await
            .ok()?;
        }
        while let Some(Ok(tokio_tungstenite::tungstenite::Message::Text(text))) = ws.next().await {
            if let Ok(gamenight_protocol::ServerMessage::PartyState { party }) =
                serde_json::from_str(&text)
            {
                if party.players.iter().any(|p| {
                    p.id == id
                        && p.name == name
                        && p.avatar.as_deref().unwrap_or("").is_empty()
                        && p.skin_color.as_deref() == Some(default_skin_color().as_str())
                }) {
                    let _ = ws.close(None).await;
                    return Some(());
                }
            }
        }
        None
    })
    .await;
    if matches!(result, Ok(Some(()))) {
        StatusCode::NO_CONTENT
    } else {
        StatusCode::BAD_GATEWAY
    }
}

async fn get_profile(
    Path(id): Path<String>,
    State(state): State<SharedState>,
) -> Result<Json<Profile>, StatusCode> {
    let state = state.lock().unwrap();
    state
        .profiles
        .get(&id)
        .cloned()
        .map(Json)
        .ok_or(StatusCode::NOT_FOUND)
}

async fn save_profile(
    State(state): State<SharedState>,
    Json(profile): Json<Profile>,
) -> Json<Profile> {
    let mut state = state.lock().unwrap();
    state.profiles.insert(profile.id.clone(), profile.clone());
    Json(profile)
}

mod daemon;
use daemon::{read_welcome, wait_for_new_player};

/// No join request may wait indefinitely on a daemon connection.
async fn join_session(
    id: Path<String>,
    state: State<SharedState>,
    request: Json<JoinSessionRequest>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    tokio::time::timeout(
        daemon::REPLY_TIMEOUT * 3,
        join_session_inner(id, state, request),
    )
    .await
    .map_err(|_| StatusCode::GATEWAY_TIMEOUT)?
}

async fn join_session_inner(
    Path(id): Path<String>,
    State(state): State<SharedState>,
    Json(req): Json<JoinSessionRequest>,
) -> Result<Json<serde_json::Value>, StatusCode> {
    let profile = {
        let state = state.lock().unwrap();
        state
            .profiles
            .get(&id)
            .cloned()
            .ok_or(StatusCode::NOT_FOUND)?
    };

    let daemon_addr = state.lock().unwrap().daemon_addr.clone();

    let ws_url = format!("ws://{daemon_addr}");
    match tokio::time::timeout(
        daemon::REPLY_TIMEOUT,
        tokio_tungstenite::connect_async(&ws_url),
    )
    .await
    .map_err(|_| StatusCode::GATEWAY_TIMEOUT)?
    {
        Ok((mut ws_stream, _)) => {
            use futures_util::SinkExt;

            let hello = ClientMessage::Hello {
                role: gamenight_protocol::Role::Overlay,
                game: None,
                token: None,
            };
            ws_stream
                .send(tokio_tungstenite::tungstenite::Message::Text(
                    hello.to_json(),
                ))
                .await
                .map_err(|_| StatusCode::BAD_GATEWAY)?;

            // Who was in the party before we touched it, so a fresh join can
            // be identified by difference. The studio needs that id back:
            // with it, every later edit is an update to *this* player, which
            // is what makes saving-on-every-keystroke safe. Without it, each
            // save would be another `JoinParty` and the party would fill up
            // with duplicates of the same person.
            let party = read_welcome(&mut ws_stream)
                .await
                .map_err(StatusCode::from)?;
            let existing: std::collections::HashSet<PlayerId> =
                party.players.iter().map(|player| player.id).collect();

            // A seat wins over an explicit id, and is resolved now rather
            // than trusted from the URL.
            let seat_target = match req.seat {
                Some(seat) => {
                    let occupant = party
                        .seats
                        .iter()
                        .find(|s| s.index == seat)
                        .and_then(|s| s.occupant.player_id());
                    if occupant.is_none() {
                        // Loud, not silent: an empty seat used to return
                        // "claimed" and do nothing, which is indistinguishable
                        // from success and cost hours to diagnose once.
                        tracing::warn!(seat, "claim for a seat nobody is sitting in");
                        return Ok(Json(serde_json::json!({
                            "status": "no_such_seat",
                            "seat": seat,
                            "message": "Nobody is on that seat any more —                                         stand on the pad and scan again."
                        })));
                    }
                    occupant
                }
                _ => None,
            };
            let mut target = seat_target.or(req.claim);
            if let Some(target) = target {
                let revision = state
                    .lock()
                    .unwrap()
                    .link_revisions
                    .get(&target)
                    .copied()
                    .unwrap_or(0);
                if req.link_revision != revision {
                    return Ok(Json(
                        serde_json::json!({"status": "unlinked", "message": "This controller was unlinked. Scan its new QR code to sign in again."}),
                    ));
                }
            }

            // One device, one seat. If this profile is already signed in as
            // somebody who is *still in the party*, a claim on a different
            // seat is a mistake — walking to the next pad and scanning again
            // would otherwise leave one phone driving two characters with the
            // same name and face.
            let already = {
                let st = state.lock().unwrap();
                st.bindings.get(&id).copied()
            };
            if let (Some(held), Some(want)) = (already, target) {
                let still_seated = party.players.iter().any(|player| player.id == held);
                if still_seated && held != want {
                    let seat_of = |pid: PlayerId| {
                        party
                            .seats
                            .iter()
                            .find(|seat| seat.occupant.player_id() == Some(pid))
                            .map(|seat| seat.index)
                    };
                    tracing::info!(
                        profile = %id,
                        ?held,
                        ?want,
                        "refusing a second seat for one profile"
                    );
                    return Ok(Json(serde_json::json!({
                        "status": "already_signed_in",
                        "player_id": held,
                        "seat": seat_of(held),
                        "message": "You're already signed in on another \
                                    character. Leave that one first, or use a \
                                    different phone."
                    })));
                }
                // Re-claiming the seat we already hold is the normal autosave
                // path, and a stale binding (party was rebuilt) is no reason
                // to refuse.
                if !still_seated {
                    target = Some(want);
                }
            }

            // Claiming an existing character vs. adding a new party member.
            let messages = match target {
                Some(player_id) => vec![
                    ClientMessage::RenamePlayer {
                        player_id,
                        name: profile.username.clone(),
                    },
                    ClientMessage::SetPlayerAvatar {
                        player_id,
                        avatar: profile.avatar.clone(),
                    },
                ],
                None => vec![ClientMessage::JoinParty {
                    name: profile.username.clone(),
                    seat: None,
                    color: None,
                    avatar: Some(profile.avatar.clone()),
                    library: Vec::new(),
                }],
            };
            for msg in &messages {
                ws_stream
                    .send(tokio_tungstenite::tungstenite::Message::Text(msg.to_json()))
                    .await
                    .map_err(|_| StatusCode::BAD_GATEWAY)?;
            }

            // A fresh join has to report which player it created.
            let player_id = match target {
                Some(id) => Some(id),
                None => Some(
                    wait_for_new_player(&mut ws_stream, &existing)
                        .await
                        .map_err(StatusCode::from)?,
                ),
            };

            if let Some(pid) = player_id {
                state.lock().unwrap().bindings.insert(id.clone(), pid);
            }

            if let Some(player_id) = player_id {
                ws_stream
                    .send(tokio_tungstenite::tungstenite::Message::Text(
                        ClientMessage::SetPlayerSkinColor {
                            player_id,
                            skin_color: profile.skin_color.clone(),
                        }
                        .to_json(),
                    ))
                    .await
                    .map_err(|_| StatusCode::BAD_GATEWAY)?;
            }

            // Close politely rather than dropping the socket mid-flight. The
            // sends above are flushed, but an abrupt drop shows up daemon-side
            // as a connect/disconnect pair with no explanation, which is a
            // miserable thing to debug.
            let _ = ws_stream.close(None).await;

            Ok(Json(serde_json::json!({
                "status": if target.is_some() { "claimed" } else { "joined" },
                "player": profile.username,
                "player_id": player_id,
                "claimed": target,
                "seat": req.seat
            })))
        }
        Err(e) => {
            tracing::error!("Failed to connect to GameNight daemon at {ws_url}: {e}");
            Err(StatusCode::BAD_GATEWAY)
        }
    }
}

async fn serve_qr() -> Response {
    // LAN address, not loopback: these codes exist to be scanned by a phone.
    let url = format!("{}/mobile", gamenight_protocol::web_base_url());
    let code = QrCode::new(url.as_bytes()).unwrap();
    let svg_xml = code
        .render::<svg::Color>()
        .min_dimensions(200, 200)
        .dark_color(svg::Color("#6366f1"))
        .light_color(svg::Color("#0f172a"))
        .build();

    (
        [(
            axum::http::header::CONTENT_TYPE,
            HeaderValue::from_static("image/svg+xml"),
        )],
        svg_xml,
    )
        .into_response()
}

async fn serve_session_qr(Path(session_id): Path<String>) -> Response {
    let url = format!(
        "{}/session/{}",
        gamenight_protocol::web_base_url(),
        session_id
    );
    let code = QrCode::new(url.as_bytes()).unwrap();
    let svg_xml = code
        .render::<svg::Color>()
        .min_dimensions(220, 220)
        .dark_color(svg::Color("#6366f1"))
        .light_color(svg::Color("#0f172a"))
        .build();

    (
        [(
            axum::http::header::CONTENT_TYPE,
            HeaderValue::from_static("image/svg+xml"),
        )],
        svg_xml,
    )
        .into_response()
}

// Embed the lobby assets so installed/offline studios use the same artwork.
async fn serve_character(Path(theme): Path<String>) -> Response {
    let png: &'static [u8] = match theme.as_str() {
        "living-room" => include_bytes!("../../lobby/assets/player/skins/fishy/fishy-body.png"),
        "underwater" => include_bytes!("../../lobby/assets/themes/underwater/fishy/body.png"),
        "sky" => include_bytes!("../../lobby/assets/themes/sky/fishy/body.png"),
        "school" => include_bytes!("../../lobby/assets/themes/school/fishy/body.png"),
        "gameroom" => include_bytes!("../../lobby/assets/themes/gameroom/fishy/body.png"),
        _ => return StatusCode::NOT_FOUND.into_response(),
    };
    (
        [("content-type", "image/png"), ("cache-control", "no-cache")],
        png,
    )
        .into_response()
}

async fn serve_studio(
    State(state): State<SharedState>,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let bridge = state.lock().unwrap().cloud.clone();
    if let Some(bridge) = bridge {
        if let Some(url) = bridge.pairing_url(&query).await {
            return axum::response::Redirect::to(&url).into_response();
        }
    }
    if let Some(response) = dev_web::studio().await {
        return response;
    }
    Html(STUDIO_HTML).into_response()
}

pub static STUDIO_HTML: &str = include_str!("../../../web/studio.html");

async fn serve_web_asset(Path(asset): Path<String>) -> Response {
    let (mime, data) = match asset.as_str() {
        "storage.js" => ("text/javascript", include_str!("../../../web/storage.js")),
        "site.css" => ("text/css", include_str!("../../../web/site.css")),
        "studio.css" => ("text/css", include_str!("../../../web/studio.css")),
        "studio.js" => ("text/javascript", include_str!("../../../web/studio.js")),
        "account.js" => ("text/javascript", include_str!("../../../web/account.js")),
        "shell.js" => ("text/javascript", include_str!("../../../web/shell.js")),
        "icon.svg" => ("image/svg+xml", include_str!("../../../web/icon.svg")),
        _ => return StatusCode::NOT_FOUND.into_response(),
    };
    ([("content-type", mime)], data).into_response()
}

#[cfg(test)]
mod room_pickup_tests {
    use super::*;
    #[tokio::test]
    async fn pickup_requires_local_peer_and_native_header() {
        let state = Arc::new(Mutex::new(ServerState::new("127.0.0.1:1".into())));
        let player = PlayerId(uuid::Uuid::new_v4());
        for (peer, native, expected) in [
            ("192.168.1.20:1234", true, StatusCode::FORBIDDEN),
            ("127.0.0.1:1234", false, StatusCode::FORBIDDEN),
            ("127.0.0.1:1234", true, StatusCode::GONE),
        ] {
            let mut headers = axum::http::HeaderMap::new();
            if native {
                headers.insert("x-gamenight-local-pickup", "1".parse().unwrap());
            }
            assert_eq!(
                room_pickup(
                    axum::extract::ConnectInfo(peer.parse().unwrap()),
                    headers,
                    Path(("pending".into(), player)),
                    State(state.clone())
                )
                .await,
                expected
            );
        }
    }
}
