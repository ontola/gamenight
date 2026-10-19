//! Native-host preferences and a recovery UI. Never exposed as LAN control APIs.
use crate::{daemon, SharedState};
use axum::{
    extract::{ConnectInfo, State},
    http::{HeaderMap, StatusCode},
    response::Html,
    Json,
};
use futures_util::{SinkExt, StreamExt};
use gamenight_protocol::{ClientMessage, GameMeta, LobbyChoice, Role, ServerMessage};
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
/// Lobbies the app ships with, then locally registered ones. The first
/// bundled lobby is the default until the host picks another one.
fn available(registrations: &Path, bundled: Option<&Path>) -> Vec<GameMeta> {
    let mut all = bundled.map(choices).unwrap_or_default();
    for meta in choices(registrations) {
        if !all.iter().any(|m| m.id == meta.id) {
            all.push(meta);
        }
    }
    all
}
/// The lobby to run: the saved choice while it is still there, else the
/// first bundled lobby. `None` only when no lobby is available at all. An
/// old saved `lobby` (the retired Clubhouse) is no longer a choice, so it
/// falls back to the default like any other missing lobby.
pub fn selected(config: &Path, registrations: &Path, bundled: Option<&Path>) -> Option<GameMeta> {
    let value: Option<Value> = std::fs::read(config)
        .ok()
        .and_then(|v| serde_json::from_slice(&v).ok());
    let id = value.as_ref().and_then(|v| v["id"].as_str());
    let all = available(registrations, bundled);
    let default = bundled.map(choices).unwrap_or_default().into_iter().next();
    id.and_then(|id| all.into_iter().find(|m| m.id.0 == id))
        .or(default)
}
fn native(peer: SocketAddr, headers: &HeaderMap) -> bool {
    peer.ip().is_loopback()
        && headers
            .get("x-gamenight-host")
            .and_then(|v| v.to_str().ok())
            == Some("1")
}
pub type Paths = (
    std::path::PathBuf,
    std::path::PathBuf,
    Option<std::path::PathBuf>,
);
fn paths() -> Result<Paths, StatusCode> {
    Ok((
        std::env::var_os("GAMENIGHT_LOBBY_CONFIG")
            .ok_or(StatusCode::NOT_IMPLEMENTED)?
            .into(),
        std::env::var_os("GAMENIGHT_LOCAL_GAMES")
            .ok_or(StatusCode::NOT_IMPLEMENTED)?
            .into(),
        std::env::var_os("GAMENIGHT_BUNDLED_LOBBIES").map(Into::into),
    ))
}
/// Lobbies the host offers: bundled ones, then installed ones, with the one
/// that runs now marked `current`.
pub fn list(config: &Path, registrations: &Path, bundled: Option<&Path>) -> Vec<LobbyChoice> {
    let current = selected(config, registrations, bundled).map(|m| m.id);
    available(registrations, bundled)
        .into_iter()
        .map(|m| LobbyChoice {
            current: current.as_ref() == Some(&m.id),
            id: m.id,
            title: m.title,
        })
        .collect()
}
/// Remember `id` as the lobby to run from the next start. False when it is
/// not a lobby this host has.
pub fn save(
    config: &Path,
    registrations: &Path,
    bundled: Option<&Path>,
    id: &str,
) -> std::io::Result<bool> {
    if !available(registrations, bundled)
        .iter()
        .any(|m| m.id.0 == id)
    {
        return Ok(false);
    }
    std::fs::write(config, json!({ "id": id }).to_string())?;
    Ok(true)
}
/// The launcher's lobby files, when this host was started by the launcher.
pub fn host_paths() -> Option<Paths> {
    paths().ok()
}
pub async fn get(ConnectInfo(peer): ConnectInfo<SocketAddr>) -> Result<Json<Value>, StatusCode> {
    if !peer.ip().is_loopback() {
        return Err(StatusCode::FORBIDDEN);
    }
    let (config, registrations, bundled) = paths()?;
    let lobbies = list(&config, &registrations, bundled.as_deref());
    let current = lobbies.iter().find(|l| l.current).map(|l| l.id.0.clone());
    let entries: Vec<Value> = lobbies
        .into_iter()
        .map(|l| json!({"id":l.id,"title":l.title}))
        .collect();
    Ok(Json(json!({"selected":current,"choices":entries})))
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
    let (config, registrations, bundled) = paths()?;
    match save(&config, &registrations, bundled.as_deref(), &request.id) {
        Ok(true) => Ok(StatusCode::NO_CONTENT),
        Ok(false) => Err(StatusCode::BAD_REQUEST),
        Err(_) => Err(StatusCode::INTERNAL_SERVER_ERROR),
    }
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
        assert_eq!(selected(&config, &games, None).unwrap().id.0, "custom");
        std::fs::write(&config, r#"{"id":"ordinary"}"#).unwrap();
        assert!(selected(&config, &games, None).is_none());
        std::fs::remove_file(games).unwrap();
        std::fs::remove_file(config).unwrap();
        std::fs::remove_dir(dir).unwrap();
    }
    #[test]
    fn bundled_lobby_is_the_default_and_replaces_the_retired_clubhouse() {
        let dir = std::env::temp_dir().join(format!("lobby-bundled-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        let bundled = dir.join("bundled.json");
        let games = dir.join("games.json");
        let config = dir.join("selected.json");
        std::fs::write(&bundled,json!([{ "id":"game-room","title":"Game Room", "launch":{"command":std::env::current_exe().unwrap(),"env":{"GAMENIGHT_LOBBY_API":"1"}}}]).to_string()).unwrap();
        std::fs::write(&games, "[]").unwrap();
        let pick = |c: &Path| selected(c, &games, Some(&bundled)).map(|m| m.id.0);
        assert_eq!(pick(&config).as_deref(), Some("game-room"));
        // A choice saved while the Clubhouse still shipped.
        std::fs::write(&config, r#"{"id":"lobby"}"#).unwrap();
        assert_eq!(pick(&config).as_deref(), Some("game-room"));
        assert!(!save(&config, &games, Some(&bundled), "lobby").unwrap());
        let listed = list(&config, &games, Some(&bundled));
        assert_eq!(listed.len(), 1);
        assert!(listed[0].current && listed[0].id.0 == "game-room");
        std::fs::write(&config, r#"{"id":"removed"}"#).unwrap();
        assert_eq!(pick(&config).as_deref(), Some("game-room"));
        std::fs::remove_dir_all(dir).unwrap();
    }
}
