//! First-launch catalog selection uses the registered gamenight:// OS link.
//! The hosted website is the only browser UI; the native app accepts catalog IDs.
use crate::daemon;
use crate::SharedState;
use axum::http::StatusCode;
use futures_util::{SinkExt, StreamExt};
use gamenight_protocol::{ClientMessage, GameId, PartySnapshot, Role, ServerMessage};
use serde_json::{json, Value};
use std::{path::PathBuf, time::Duration};
use tokio_tungstenite::tungstenite::Message;

pub(crate) fn start(state: &SharedState) {
    let Some(file) = std::env::var_os("GAMENIGHT_ONBOARDING_FILE").map(PathBuf::from) else {
        return;
    };
    listen_for_catalog_requests(state.clone(), file.clone());
    let Some(saved) = std::fs::read(&file)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
    else {
        return;
    };
    if saved["complete"] == true {
        return;
    }
    let state = state.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(1)).await;
        if let Some(game) = saved["game"].as_str().filter(|id| allowed(id)) {
            let addr = state.lock().unwrap().daemon_addr.clone();
            if let Ok(installed) = queue(&addr, game).await {
                let _ = std::fs::write(file, json!({"complete":installed,"game":game}).to_string());
                return;
            }
        }
        if std::env::var("GAMENIGHT_OFFLINE").as_deref() != Ok("1") {
            let url = format!(
                "{}/play#setup={}",
                gamenight_protocol::web_base_url().trim_end_matches('/'),
                gamenight_catalog::current_platform()
            );
            if let Err(error) = open_browser(&url) {
                tracing::warn!(%error, "Could not open hosted setup; local play remains available");
            }
        }
    });
}

async fn open_lobby(addr: &str) -> Result<(), StatusCode> {
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
    ws.send(Message::Text(ClientMessage::RetryLobby.to_json()))
        .await
        .map_err(|_| StatusCode::BAD_GATEWAY)?;
    ws.send(Message::Text(ClientMessage::OpenOverlay.to_json()))
        .await
        .map_err(|_| StatusCode::BAD_GATEWAY)?;
    Ok(())
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
            if value
                .as_ref()
                .is_some_and(|v| v.get("game").is_some_and(Value::is_null))
            {
                let _ = std::fs::write(&file, json!({"complete":true}).to_string());
                let addr = state.lock().unwrap().daemon_addr.clone();
                let _ = open_lobby(&addr).await;
                continue;
            }
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
