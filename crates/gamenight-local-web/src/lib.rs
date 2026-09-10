use axum::{
    extract::{Path, State},
    http::{HeaderValue, StatusCode},
    response::{Html, IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
mod playlist;
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
    pub color: String,
    pub avatar: String, // 16x16 pixel matrix serialized or data URI
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
        .route("/studio", get(serve_studio))
        .route("/mobile", get(serve_studio))
        .route("/session/:session_id", get(serve_studio))
        .route(
            "/api/playlist",
            get(playlist::get).post(playlist::move_entry),
        )
        .route("/api/player-links", get(player_links))
        .route("/api/player-links/:id/unlink", post(unlink_player))
        .route("/api/profiles", post(save_profile))
        .route("/api/profiles/:id", get(get_profile))
        .route("/api/profiles/:id/join", post(join_session))
        .route("/qr", get(serve_qr))
        .route("/qr/:session_id", get(serve_session_qr))
        .route("/", get(serve_studio))
        .with_state(state)
}

pub async fn run_server(
    addr: std::net::SocketAddr,
    state: SharedState,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let app = create_router(state);
    let listener = tokio::net::TcpListener::bind(addr).await?;
    // Log the address a phone can actually use, not just the bind address —
    // `0.0.0.0` is not something anyone can type into a browser.
    tracing::info!(
        "🌐 GameNight Web Server & Studio bound to {addr}, reachable at {}",
        gamenight_protocol::web_base_url()
    );
    axum::serve(listener, app).await?;
    Ok(())
}

async fn player_links(State(state): State<SharedState>) -> Json<serde_json::Value> {
    let state = state.lock().unwrap();
    Json(serde_json::json!({"linked": state.bindings.values().collect::<Vec<_>>(), "revisions": state.link_revisions}))
}

async fn unlink_player(Path(id): Path<PlayerId>, State(state): State<SharedState>) -> StatusCode {
    let mut state = state.lock().unwrap();
    state.bindings.retain(|_, player| *player != id);
    *state.link_revisions.entry(id).or_default() += 1;
    StatusCode::NO_CONTENT
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
                let revision = state.lock().unwrap().link_revisions.get(&target).copied().unwrap_or(0);
                if req.link_revision != revision {
                    return Ok(Json(serde_json::json!({"status": "unlinked", "message": "This controller was unlinked. Scan its new QR code to sign in again."})));
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
                    ClientMessage::SetPlayerColor {
                        player_id,
                        color: profile.color.clone(),
                    },
                    ClientMessage::SetPlayerAvatar {
                        player_id,
                        avatar: profile.avatar.clone(),
                    },
                ],
                None => vec![ClientMessage::JoinParty {
                    name: profile.username.clone(),
                    seat: None,
                    color: Some(profile.color.clone()),
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

async fn serve_studio() -> Html<&'static str> {
    Html(STUDIO_HTML)
}

pub static STUDIO_HTML: &str = include_str!("studio.html");
