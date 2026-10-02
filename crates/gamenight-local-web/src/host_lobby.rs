//! Native-host preferences and a recovery UI. Never exposed as LAN control APIs.
use crate::{daemon, SharedState};
use axum::{
    extract::{ConnectInfo, State},
    http::{HeaderMap, StatusCode},
    response::Html,
    Json,
};
use futures_util::{SinkExt, StreamExt};
use gamenight_protocol::{ClientMessage, GameMeta, Role, ServerMessage};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{net::SocketAddr, path::Path};
use tokio_tungstenite::tungstenite::Message;

pub fn choices(path: &Path) -> Vec<GameMeta> {
    std::fs::read(path)
        .ok()
        .and_then(|v| serde_json::from_slice::<Vec<GameMeta>>(&v).ok())
        .unwrap_or_default()
        .into_iter()
        .filter(|m| {
            m.id.0 != "lobby"
                && m.launch.as_ref().is_some_and(|l| {
                    l.env.get("GAMENIGHT_LOBBY_API").is_some_and(|v| v == "1")
                        && Path::new(&l.command).is_absolute()
                        && Path::new(&l.command).is_file()
                        && l.cwd.as_ref().is_none_or(|cwd| {
                            Path::new(cwd).is_absolute() && Path::new(cwd).is_dir()
                        })
                })
        })
        .collect()
}
pub fn selected(config: &Path, registrations: &Path) -> Option<GameMeta> {
    let value: Value = serde_json::from_slice(&std::fs::read(config).ok()?).ok()?;
    choices(registrations)
        .into_iter()
        .find(|m| value["id"].as_str() == Some(m.id.0.as_str()))
}
fn native(peer: SocketAddr, headers: &HeaderMap) -> bool {
    peer.ip().is_loopback()
        && headers
            .get("x-gamenight-host")
            .and_then(|v| v.to_str().ok())
            == Some("1")
}
fn paths() -> Result<(std::path::PathBuf, std::path::PathBuf), StatusCode> {
    Ok((
        std::env::var_os("GAMENIGHT_LOBBY_CONFIG")
            .ok_or(StatusCode::NOT_IMPLEMENTED)?
            .into(),
        std::env::var_os("GAMENIGHT_LOCAL_GAMES")
            .ok_or(StatusCode::NOT_IMPLEMENTED)?
            .into(),
    ))
}
pub async fn get(ConnectInfo(peer): ConnectInfo<SocketAddr>) -> Result<Json<Value>, StatusCode> {
    if !peer.ip().is_loopback() {
        return Err(StatusCode::FORBIDDEN);
    }
    let (config, registrations) = paths()?;
    let mut entries = vec![json!({"id":"lobby","title":"GameNight platformer"})];
    entries.extend(
        choices(&registrations)
            .into_iter()
            .map(|m| json!({"id":m.id,"title":m.title})),
    );
    Ok(Json(
        json!({"selected":selected(&config,&registrations).map(|m|m.id.0).unwrap_or("lobby".into()),"choices":entries}),
    ))
}
#[derive(Deserialize)]
pub struct Selection {
    id: String,
}
pub async fn select(
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Json(request): Json<Selection>,
) -> Result<StatusCode, StatusCode> {
    if !native(peer, &headers) {
        return Err(StatusCode::FORBIDDEN);
    }
    let (config, registrations) = paths()?;
    if request.id != "lobby" && !choices(&registrations).iter().any(|m| m.id.0 == request.id) {
        return Err(StatusCode::BAD_REQUEST);
    }
    std::fs::write(config, json!({"id":request.id}).to_string())
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    Ok(StatusCode::NO_CONTENT)
}
#[derive(Deserialize)]
pub struct Recovery {
    action: String,
}
pub async fn recover(
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    State(state): State<SharedState>,
    Json(request): Json<Recovery>,
) -> Result<StatusCode, StatusCode> {
    if !native(peer, &headers) {
        return Err(StatusCode::FORBIDDEN);
    }
    let command = match request.action.as_str() {
        "retry" => ClientMessage::RetryLobby,
        "resume" => ClientMessage::CloseOverlay,
        "quit" => ClientMessage::QuitParty,
        _ => return Err(StatusCode::BAD_REQUEST),
    };
    let addr = state.lock().unwrap().daemon_addr.clone();
    tokio::time::timeout(std::time::Duration::from_secs(5), async {
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
        ws.send(Message::Text(command.to_json()))
            .await
            .map_err(|_| StatusCode::BAD_GATEWAY)?;
        while let Some(message) = ws.next().await {
            let message = message.map_err(|_| StatusCode::BAD_GATEWAY)?;
            if let Message::Text(text) = message {
                match serde_json::from_str::<ServerMessage>(&text) {
                    Ok(ServerMessage::Error { .. }) => return Err(StatusCode::CONFLICT),
                    Ok(ServerMessage::PartyState { .. }) => return Ok(StatusCode::NO_CONTENT),
                    _ => {}
                }
            }
        }
        Err(StatusCode::BAD_GATEWAY)
    })
    .await
    .map_err(|_| StatusCode::GATEWAY_TIMEOUT)?
}
pub async fn page(
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
) -> Result<Html<&'static str>, StatusCode> {
    if !peer.ip().is_loopback() {
        return Err(StatusCode::FORBIDDEN);
    }
    Ok(Html(include_str!("../../../web/host-lobby.html")))
}
pub fn open_recovery() -> std::io::Result<()> {
    crate::onboarding::open_browser(&format!(
        "http://127.0.0.1:{}/host/lobby?recovery=1",
        gamenight_protocol::DEFAULT_WEB_PORT
    ))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_controls_reject_lan_and_browser_simple_posts() {
        let mut headers = HeaderMap::new();
        assert!(!native("127.0.0.1:1".parse().unwrap(), &headers));
        headers.insert("x-gamenight-host", "1".parse().unwrap());
        assert!(native("127.0.0.1:1".parse().unwrap(), &headers));
        assert!(!native("192.0.2.1:1".parse().unwrap(), &headers));
    }
    #[test]
    fn selection_requires_registered_installed_lobby() {
        let dir = std::env::temp_dir().join(format!("lobby-choice-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        let games = dir.join("games.json");
        let config = dir.join("selected.json");
        std::fs::write(&games,json!([{ "id":"custom","title":"Custom", "launch":{"command":std::env::current_exe().unwrap(),"env":{"GAMENIGHT_LOBBY_API":"1"}}},{"id":"ordinary","title":"Game"}]).to_string()).unwrap();
        std::fs::write(&config, r#"{"id":"custom"}"#).unwrap();
        assert_eq!(selected(&config, &games).unwrap().id.0, "custom");
        std::fs::write(&config, r#"{"id":"ordinary"}"#).unwrap();
        assert!(selected(&config, &games).is_none());
        std::fs::remove_file(games).unwrap();
        std::fs::remove_file(config).unwrap();
        std::fs::remove_dir(dir).unwrap();
    }
}
