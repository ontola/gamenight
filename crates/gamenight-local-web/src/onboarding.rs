//! Optional first-run catalog handoff. The browser carries a game ID, never a
//! URL or launch command. A short-lived capability binds it to this local app.
use crate::{daemon, SharedState};
use axum::{
    extract::{ConnectInfo, State},
    http::{HeaderMap, StatusCode},
    response::Html,
    Json,
};
use futures_util::{SinkExt, StreamExt};
use gamenight_protocol::{ClientMessage, GameId, PartySnapshot, Role, ServerMessage};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    net::SocketAddr,
    path::PathBuf,
    time::{Duration, Instant},
};
use tokio_tungstenite::tungstenite::Message;

pub(crate) struct Handoff {
    ticket: String,
    expires: Instant,
    file: PathBuf,
    busy: bool,
    accepted: Option<String>,
}

pub(crate) fn start(state: &SharedState, port: u16) {
    let Some(file) = std::env::var_os("GAMENIGHT_ONBOARDING_FILE").map(PathBuf::from) else {
        return;
    };
    listen_for_catalog_requests(state.clone(), file.clone());
    let Ok(bytes) = std::fs::read(&file) else {
        return;
    };
    let Ok(saved) = serde_json::from_slice::<Value>(&bytes) else {
        return;
    };
    if saved["complete"] == true {
        return;
    }
    let ticket = uuid::Uuid::new_v4().simple().to_string();
    state.lock().unwrap().onboarding = Some(Handoff {
        ticket: ticket.clone(),
        expires: Instant::now() + Duration::from_secs(1200),
        file,
        busy: false,
        accepted: None,
    });
    let state = state.clone();
    tokio::spawn(async move {
        // The daemon's socket starts just after the local web task.
        tokio::time::sleep(Duration::from_secs(1)).await;
        if let Some(game) = saved["game"].as_str() {
            if complete(&state, &ticket, Some(game)).await.is_ok() {
                return;
            }
        }
        let url = format!(
            "https://gamenight.ontola.io/play#desktop={ticket}&port={port}&platform={}",
            gamenight_catalog::current_platform()
        );
        if let Err(error) = open_browser(&url) {
            tracing::warn!(%error, "Could not open catalog setup; local play is still available");
        }
    });
}

fn listen_for_catalog_requests(state: SharedState, file: PathBuf) {
    tokio::spawn(async move {
        let Some(directory) = file.parent() else {
            return;
        };
        let request = directory.join("catalog-request.json");
        loop {
            tokio::time::sleep(Duration::from_millis(250)).await;
            let processing = directory.join(format!(
                "catalog-request-{}.processing",
                uuid::Uuid::new_v4()
            ));
            // Claim atomically, so a second launcher can submit the next choice
            // while this one waits for the daemon acknowledgement.
            if std::fs::rename(&request, &processing).is_err() {
                continue;
            }
            let value = std::fs::read(&processing)
                .ok()
                .and_then(|v| serde_json::from_slice::<Value>(&v).ok());
            let _ = std::fs::remove_file(processing);
            let Some(game) = value
                .as_ref()
                .and_then(|v| v["game"].as_str())
                .filter(|g| allowed(g))
            else {
                continue;
            };
            let addr = state.lock().unwrap().daemon_addr.clone();
            if std::fs::write(&file, json!({"complete":false,"game":game}).to_string()).is_err() {
                continue;
            }
            match queue(&addr, game).await {
                Ok(installed) => {
                    let _ = std::fs::write(
                        &file,
                        json!({"complete":installed,"game":game}).to_string(),
                    );
                }
                Err(error) => {
                    tracing::warn!(%game, %error, "Catalog selection could not reach the lobby; saved for next launch")
                }
            }
        }
    });
}

/// Refresh an expired setup in the local page, without restarting the app.
pub(crate) async fn reconnect(
    State(state): State<SharedState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Json(_): Json<Value>,
) -> Result<Json<Value>, StatusCode> {
    let host = headers
        .get("host")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    let local_host = host
        .split(':')
        .next()
        .is_some_and(|h| h == "127.0.0.1" || h == "localhost");
    if !peer.ip().is_loopback()
        || !local_host
        || headers.get("origin").and_then(|v| v.to_str().ok())
            != Some(format!("http://{host}").as_str())
    {
        return Err(StatusCode::FORBIDDEN);
    }
    let file = std::env::var_os("GAMENIGHT_ONBOARDING_FILE")
        .map(PathBuf::from)
        .ok_or(StatusCode::NOT_FOUND)?;
    let saved = std::fs::read(&file)
        .ok()
        .and_then(|v| serde_json::from_slice::<Value>(&v).ok());
    let mut local = state.lock().unwrap();
    if local.onboarding.as_ref().is_some_and(|h| h.busy) {
        return Err(StatusCode::CONFLICT);
    }
    let ticket = uuid::Uuid::new_v4().simple().to_string();
    local.onboarding = Some(Handoff {
        ticket: ticket.clone(),
        expires: Instant::now() + Duration::from_secs(1200),
        file,
        busy: false,
        accepted: None,
    });
    let games = gamenight_catalog::load_dir(&gamenight_catalog::catalog_dir())
        .unwrap_or_default()
        .into_iter()
        .filter(|g| {
            g.auto_download_here().is_some() && !["lobby", "demo-game"].contains(&g.id.as_str())
        })
        .map(|g| json!({"id":g.id,"title":g.title}))
        .collect::<Vec<_>>();
    Ok(Json(
        json!({"ticket":ticket,"game":saved.and_then(|v| v["game"].as_str().map(str::to_owned)),"games":games}),
    ))
}

pub(crate) fn open_browser(url: &str) -> std::io::Result<()> {
    // Packaged hosts run in a Windows kill-on-close job. Let the launcher,
    // outside that job, open the browser so it never becomes a game descendant.
    if let Some(path) = std::env::var_os("GAMENIGHT_BROWSER_REQUEST") {
        return std::fs::write(path, url);
    }
    #[cfg(windows)]
    let mut command = {
        use std::os::windows::process::CommandExt;
        let mut cmd = std::process::Command::new("rundll32.exe");
        cmd.args(["url.dll,FileProtocolHandler", url])
            .creation_flags(0x08000000);
        cmd
    };
    #[cfg(target_os = "macos")]
    let mut command = {
        let mut cmd = std::process::Command::new("open");
        cmd.arg(url);
        cmd
    };
    #[cfg(not(any(windows, target_os = "macos")))]
    let mut command = {
        let mut cmd = std::process::Command::new("xdg-open");
        cmd.arg(url);
        cmd
    };
    command.spawn().map(|_| ())
}

pub(crate) async fn page() -> impl axum::response::IntoResponse {
    (
        [
            ("cache-control", "no-store"),
            ("referrer-policy", "no-referrer"),
        ],
        Html(include_str!("../assets/onboarding.html")),
    )
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Request {
    ticket: String,
    game: Option<String>,
}

pub(crate) async fn claim(
    State(state): State<SharedState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    Json(request): Json<Request>,
) -> Result<Json<Value>, StatusCode> {
    if !peer.ip().is_loopback() {
        return Err(StatusCode::FORBIDDEN);
    }
    complete(&state, &request.ticket, request.game.as_deref()).await?;
    Ok(Json(json!({"accepted":true})))
}

fn allowed(game: &str) -> bool {
    game.len() <= 80
        && !["lobby", "demo-game"].contains(&game)
        && gamenight_catalog::load_dir(&gamenight_catalog::catalog_dir()).is_ok_and(|entries| {
            entries
                .iter()
                .any(|entry| entry.id == game && entry.auto_download_here().is_some())
        })
}

async fn complete(state: &SharedState, ticket: &str, game: Option<&str>) -> Result<(), StatusCode> {
    let (file, addr) = {
        let mut local = state.lock().unwrap();
        let addr = local.daemon_addr.clone();
        let handoff = local.onboarding.as_mut().ok_or(StatusCode::GONE)?;
        if ticket != handoff.ticket || handoff.expires <= Instant::now() {
            return Err(StatusCode::FORBIDDEN);
        }
        let selection = game.unwrap_or("");
        if let Some(accepted) = &handoff.accepted {
            return if accepted == selection {
                Ok(())
            } else {
                Err(StatusCode::CONFLICT)
            };
        }
        if handoff.busy {
            return Err(StatusCode::CONFLICT);
        }
        if game.is_some_and(|game| !allowed(game)) {
            return Err(StatusCode::UNPROCESSABLE_ENTITY);
        }
        handoff.busy = true;
        (handoff.file.clone(), addr)
    };
    // Persist the requested ID before contacting the daemon. A crash or an
    // interrupted download keeps the choice for the next desktop launch.
    let result = async {
        std::fs::write(&file, json!({"complete":false,"game":game}).to_string())
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        let installed = match game {
            Some(game) => queue(&addr, game).await?,
            None => true,
        };
        // Until installed, resume this choice on the next launch as well.
        std::fs::write(&file, json!({"complete":installed,"game":game}).to_string())
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        Ok(())
    }
    .await;
    let mut local = state.lock().unwrap();
    if let Some(handoff) = local.onboarding.as_mut() {
        handoff.busy = false;
        if result.is_ok() {
            handoff.accepted = Some(game.unwrap_or("").to_owned());
        }
    }
    result
}

fn selected(party: &PartySnapshot, game: &GameId) -> bool {
    party
        .warming
        .as_ref()
        .is_some_and(|next| &next.game == game)
        || party
            .warm_session
            .as_ref()
            .is_some_and(|next| &next.game == game)
}

async fn queue(addr: &str, game: &str) -> Result<bool, StatusCode> {
    tokio::time::timeout(Duration::from_secs(10), async {
        let (mut ws, _) = tokio_tungstenite::connect_async(format!("ws://{addr}"))
            .await
            .map_err(|_| StatusCode::BAD_GATEWAY)?;
        ws.send(Message::Text(
            ClientMessage::Hello {
                role: Role::Overlay,
                game: None,
                token: None,
            }
            .to_json(),
        ))
        .await
        .map_err(|_| StatusCode::BAD_GATEWAY)?;
        daemon::read_welcome(&mut ws)
            .await
            .map_err(StatusCode::from)?;
        let id = GameId::new(game);
        ws.send(Message::Text(
            ClientMessage::QueueNext { game: id.clone() }.to_json(),
        ))
        .await
        .map_err(|_| StatusCode::BAD_GATEWAY)?;
        while let Some(message) = ws.next().await {
            if let Message::Text(text) = message.map_err(|_| StatusCode::BAD_GATEWAY)? {
                match serde_json::from_str::<ServerMessage>(&text)
                    .map_err(|_| StatusCode::BAD_GATEWAY)?
                {
                    ServerMessage::PartyState { party } if selected(&party, &id) => {
                        return Ok(party
                            .library
                            .iter()
                            .any(|entry| entry.id == id && entry.launch.is_some()))
                    }
                    ServerMessage::Error { .. } => return Err(StatusCode::CONFLICT),
                    _ => {}
                }
            }
        }
        Err(StatusCode::BAD_GATEWAY)
    })
    .await
    .map_err(|_| StatusCode::GATEWAY_TIMEOUT)?
    // QueueNext deliberately does not issue Start or steal focus. The lobby
    // already renders this selection and its genuine installer progress.
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ServerState;
    use std::sync::{Arc, Mutex};

    fn fixture() -> (SharedState, PathBuf) {
        let file = std::env::temp_dir().join(format!(
            "gamenight-onboarding-{}.json",
            uuid::Uuid::new_v4()
        ));
        let mut state = ServerState::new("127.0.0.1:1".into());
        state.onboarding = Some(Handoff {
            ticket: "test-ticket".into(),
            expires: Instant::now() + Duration::from_secs(60),
            file: file.clone(),
            busy: false,
            accepted: None,
        });
        (Arc::new(Mutex::new(state)), file)
    }

    #[tokio::test]
    async fn capability_expires_and_cannot_be_reused_for_a_different_choice() {
        let (state, file) = fixture();
        assert_eq!(
            complete(&state, "wrong", None).await,
            Err(StatusCode::FORBIDDEN)
        );
        assert!(!file.exists());
        assert_eq!(
            complete(&state, "test-ticket", Some("../../bad")).await,
            Err(StatusCode::UNPROCESSABLE_ENTITY)
        );
        assert!(!file.exists());
        complete(&state, "test-ticket", None).await.unwrap();
        complete(&state, "test-ticket", None).await.unwrap();
        assert_eq!(
            complete(&state, "test-ticket", Some("blast-party")).await,
            Err(StatusCode::CONFLICT)
        );
        assert_eq!(
            serde_json::from_slice::<Value>(&std::fs::read(&file).unwrap()).unwrap()["complete"],
            true
        );
        state.lock().unwrap().onboarding.as_mut().unwrap().expires = Instant::now();
        assert_eq!(
            complete(&state, "test-ticket", None).await,
            Err(StatusCode::FORBIDDEN)
        );
        std::fs::remove_file(file).unwrap();
    }

    #[tokio::test]
    async fn lan_clients_cannot_claim_first_run() {
        let (state, file) = fixture();
        let result = claim(
            State(state),
            ConnectInfo("192.168.1.2:54321".parse().unwrap()),
            Json(Request {
                ticket: "test-ticket".into(),
                game: None,
            }),
        )
        .await;
        assert_eq!(result.unwrap_err(), StatusCode::FORBIDDEN);
        assert!(!file.exists());
    }

    #[tokio::test]
    async fn reconnect_rejects_cross_site_and_rebound_hosts() {
        for (peer, host, origin) in [
            (
                "192.168.1.2:4000",
                "127.0.0.1:7913",
                "http://127.0.0.1:7913",
            ),
            ("127.0.0.1:4000", "127.0.0.1:7913", "https://evil.example"),
            (
                "127.0.0.1:4000",
                "evil.example:7913",
                "http://evil.example:7913",
            ),
        ] {
            let (state, _) = fixture();
            let mut headers = HeaderMap::new();
            headers.insert("host", host.parse().unwrap());
            headers.insert("origin", origin.parse().unwrap());
            assert_eq!(
                reconnect(
                    State(state),
                    ConnectInfo(peer.parse().unwrap()),
                    headers,
                    Json(json!({}))
                )
                .await
                .unwrap_err(),
                StatusCode::FORBIDDEN
            );
        }
    }

    #[tokio::test]
    async fn queue_waits_for_host_ack_and_does_not_start_game() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let mut night = gamenight_core::GameNight::default();
        let id = GameId::new("blast-party");
        let task = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = tokio_tungstenite::accept_async(stream).await.unwrap();
            let hello = ws.next().await.unwrap().unwrap();
            assert!(hello.into_text().unwrap().contains("overlay"));
            ws.send(Message::Text(json!({"type":"welcome","protocol_version":gamenight_protocol::PROTOCOL_VERSION,"party":night.snapshot()}).to_string())).await.unwrap();
            let text = ws.next().await.unwrap().unwrap().into_text().unwrap();
            assert!(
                matches!(serde_json::from_str::<ClientMessage>(&text).unwrap(),ClientMessage::QueueNext{game} if game==id)
            );
            night.handle(gamenight_core::Command::QueueNext { game: id.clone() });
            let party = night.snapshot();
            assert!(party.active_session.is_none());
            assert!(selected(&party, &id));
            ws.send(Message::Text(ServerMessage::PartyState { party }.to_json()))
                .await
                .unwrap();
        });
        assert!(!queue(&addr.to_string(), "blast-party").await.unwrap());
        task.await.unwrap();
    }
}
