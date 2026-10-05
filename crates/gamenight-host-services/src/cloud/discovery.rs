//! Optional cloud discovery adapter. The local daemon remains the authority for
//! availability, installation and process control; cloud requests contain IDs only.
use super::Seat;
use crate::{daemon, SharedState};
use futures_util::{SinkExt, StreamExt};
use gamenight_protocol::{
    ClientMessage, GameId, InstallState, PartySnapshot, Role, ServerMessage, SessionPhase,
};
use serde::Deserialize;
use serde_json::{json, Value};
use tokio_tungstenite::tungstenite::Message;

#[derive(Deserialize)]
pub(crate) struct Selection {
    #[serde(default)]
    pub command: Option<super::settings::Command>,
    #[serde(default)]
    pub edit: Option<Value>,
    pub id: String,
    pub game: String,
    pub seat: Seat,
    pub expires: u64,
}

pub(crate) fn snapshot(party: &PartySnapshot, acknowledged: &Option<String>) -> Value {
    let mut games = Vec::new();
    let count = party
        .seats
        .iter()
        .filter(|s| s.occupant.player_id().is_some())
        .count() as u8;
    for game in &party.library {
        let install = party.installs.iter().find(|i| i.game == game.id);
        // Minimum counts are recommendations for an explicit selection, just
        // as in the daemon. Only capacity may exclude an already seated player.
        let selectable = game.max_players.is_none_or(|max| count <= max)
            && (game.launch.is_some()
                || party.connected_games.contains(&game.id)
                || install.is_some());
        let mut state = if selectable {
            "available"
        } else {
            "unavailable"
        };
        let mut percent = None;
        if game.launch.is_none() && !party.connected_games.contains(&game.id) {
            if let Some(install) = install {
                state = match install.state {
                    InstallState::Queued => "queued",
                    InstallState::Downloading => "downloading",
                    InstallState::Verifying => "verifying",
                    InstallState::Extracting => "extracting",
                    InstallState::Installed => "installed",
                    InstallState::Failed => "failed",
                };
                percent = install.percent;
            }
        }
        if party.warming.as_ref().is_some_and(|s| s.game == game.id) && install.is_none() {
            state = "loading";
        }
        if let Some(s) = party.warm_session.as_ref().filter(|s| s.game == game.id) {
            state = if s.phase == SessionPhase::Ready {
                "ready"
            } else {
                "loading"
            };
            percent = s.progress;
        }
        if party
            .active_session
            .as_ref()
            .is_some_and(|s| s.game == game.id)
        {
            state = "playing";
        }
        let issue = party.game_issues.iter().find(|issue| issue.game == game.id);
        if issue.is_some() {
            state = "stopped";
            percent = None;
        }
        games.push(json!({"id":game.id,"selectable":selectable,"state":state,"percent":percent,"issue":issue,"failure":install.filter(|i|i.state==InstallState::Failed).map(|i|failure_hint(i.label.as_deref()))}));
    }
    for install in &party.installs {
        if games.iter().any(|g| g["id"] == install.game.0) {
            continue;
        }
        games.push(json!({"id":install.game,"selectable":true,"state":install.state,"percent":install.percent,"failure":(install.state==InstallState::Failed).then(||failure_hint(install.label.as_deref()))}));
    }
    json!({"next_controls":super::settings::next_controls(party),"controls":super::settings::controls(party),"session":party.active_session,"playlist":party.playlist,"games":games,"current":party.active_session.as_ref().or(party.warm_session.as_ref()).map(|s| &s.game),"next":party.warming.as_ref().map(|s| &s.game).or_else(|| party.warm_session.as_ref().map(|s| &s.game)),"acknowledged":acknowledged})
}

fn failure_hint(label: Option<&str>) -> &'static str {
    let label = label.unwrap_or_default().to_lowercase();
    if label.contains("space") || label.contains("os error 112") || label.contains("os error 28") {
        "Free some disk space on the host, then retry."
    } else if label.contains("checksum") || label.contains("sha256") {
        "The download could not be verified. Retry to fetch a fresh copy."
    } else if label.contains("http") || label.contains("network") || label.contains("timed out") {
        "The download could not be reached. Check the host's connection, then retry."
    } else {
        "The game could not be installed. Retry the download."
    }
}

pub(crate) async fn apply(state: &SharedState, selection: &Selection) -> bool {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    if selection.expires <= now {
        return false;
    }
    let addr = {
        let local = state.lock().unwrap();
        let Ok(id) = uuid::Uuid::parse_str(&selection.seat.player) else {
            return false;
        };
        if *local
            .link_revisions
            .get(&gamenight_protocol::PlayerId(id))
            .unwrap_or(&0)
            != selection.seat.revision
        {
            return false;
        }
        local.daemon_addr.clone()
    };
    tokio::time::timeout(daemon::REPLY_TIMEOUT * 3, async {
        let (mut ws, _) = tokio_tungstenite::connect_async(format!("ws://{addr}"))
            .await
            .ok()?;
        ws.send(Message::Text(
            ClientMessage::Hello {
                role: Role::Overlay,
                game: None,
                token: None,
            }
            .to_json(),
        ))
        .await
        .ok()?;
        let party = daemon::read_welcome(&mut ws).await.ok()?;
        if !party.seats.iter().any(|s| {
            s.index == selection.seat.index
                && s.occupant
                    .player_id()
                    .is_some_and(|p| p.0.to_string() == selection.seat.player)
        }) {
            return None;
        }
        if let Some(edit) = &selection.edit {
            let request =
                serde_json::from_value::<crate::playlist::MoveRequest>(edit.clone()).ok()?;
            let _ = ws.close(None).await;
            return crate::playlist::move_entry(
                axum::extract::State(state.clone()),
                axum::Json(request),
            )
            .await
            .ok()
            .map(|_| ());
        }
        if !snapshot(&party, &None)["games"]
            .as_array()?
            .iter()
            .any(|g| g["id"] == selection.game && g["selectable"] == true)
        {
            return None;
        }
        // Retried deliveries after a lost HTTP response do not reorder the queue.
        let failed = party
            .installs
            .iter()
            .any(|i| i.game.0 == selection.game && i.state == InstallState::Failed);
        if !failed
            && (party
                .warming
                .as_ref()
                .is_some_and(|s| s.game.0 == selection.game)
                || party
                    .warm_session
                    .as_ref()
                    .is_some_and(|s| s.game.0 == selection.game))
        {
            return Some(());
        }
        ws.send(Message::Text(
            ClientMessage::QueueNext {
                game: GameId(selection.game.clone()),
            }
            .to_json(),
        ))
        .await
        .ok()?;
        while let Some(Ok(message)) = ws.next().await {
            if let Message::Text(text) = message {
                if let Ok(ServerMessage::PartyState { party }) = serde_json::from_str(&text) {
                    if party
                        .warming
                        .as_ref()
                        .is_some_and(|s| s.game.0 == selection.game)
                        || party
                            .warm_session
                            .as_ref()
                            .is_some_and(|s| s.game.0 == selection.game)
                    {
                        let _ = ws.close(None).await;
                        return Some(());
                    }
                }
            }
        }
        None
    })
    .await
    .ok()
    .flatten()
    .is_some()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn failed_installs_are_retryable_and_do_not_expose_host_paths() {
        let mut party = gamenight_core::GameNight::default().snapshot();
        party.installs.push(serde_json::from_value(json!({"game":"broken","title":"Broken","state":"failed","label":"HTTP error downloading https://secret.example/private?token=x"})).unwrap());
        let view = snapshot(&party, &None);
        assert_eq!(view["games"][0]["selectable"], true);
        assert_eq!(view["games"][0]["state"], "failed");
        assert!(!view.to_string().contains("secret"));
        assert!(view["games"][0]["failure"]
            .as_str()
            .unwrap()
            .contains("connection"));
    }
    #[test]
    fn discovery_never_exports_launch_instructions() {
        let mut party = gamenight_core::GameNight::default().snapshot();
        party.library.push(serde_json::from_value(json!({"id":"local","title":"Local","launch":{"command":"/private/game","args":[],"env":{"SECRET":"private"}}})).unwrap());
        party.library[0].min_players = Some(2);
        let view = snapshot(&party, &None);
        assert_eq!(view["games"][0]["selectable"], true);
        assert!(!view.to_string().contains("private"));
        party.installs.push(
            serde_json::from_value(
                json!({"game":"incoming","title":"Incoming","state":"downloading","percent":37}),
            )
            .unwrap(),
        );
        assert_eq!(snapshot(&party, &None)["games"][1]["percent"], 37);
        party
            .library
            .push(serde_json::from_value(json!({"id":"incoming","title":"Incoming"})).unwrap());
        let view = snapshot(&party, &None);
        assert_eq!(view["games"][1]["state"], "downloading");
        assert_eq!(view["games"][1]["selectable"], true);
    }

    #[tokio::test]
    async fn selection_reaches_the_real_daemon_and_rechecks_the_seat() {
        use crate::ServerState;
        use std::sync::{Arc, Mutex};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap().to_string();
        let server = tokio::spawn(gamenight_daemon::run_with_library(
            listener,
            vec![serde_json::from_value(
                json!({"id":"target","title":"Target","min_players":2,"max_players":4}),
            )
            .unwrap()],
        ));
        let state = Arc::new(Mutex::new(ServerState::new(addr.clone())));
        let (mut game, _) = tokio_tungstenite::connect_async(format!("ws://{addr}"))
            .await
            .unwrap();
        game.send(Message::Text(
            ClientMessage::Hello {
                role: Role::Game,
                game: Some(GameId::new("target")),
                token: None,
            }
            .to_json(),
        ))
        .await
        .unwrap();
        daemon::read_welcome(&mut game).await.unwrap();
        let (mut overlay, _) = tokio_tungstenite::connect_async(format!("ws://{addr}"))
            .await
            .unwrap();
        overlay
            .send(Message::Text(
                ClientMessage::Hello {
                    role: Role::Overlay,
                    game: None,
                    token: None,
                }
                .to_json(),
            ))
            .await
            .unwrap();
        daemon::read_welcome(&mut overlay).await.unwrap();
        overlay
            .send(Message::Text(
                ClientMessage::JoinParty {
                    name: "Player".into(),
                    seat: Some(0),
                    color: None,
                    avatar: None,
                    library: vec![],
                }
                .to_json(),
            ))
            .await
            .unwrap();
        let player = daemon::wait_for_new_player(&mut overlay, &std::collections::HashSet::new())
            .await
            .unwrap();
        let mut selection = Selection {
            edit: None,
            command: None,
            id: uuid::Uuid::new_v4().to_string(),
            game: "target".into(),
            seat: Seat {
                index: 0,
                player: player.0.to_string(),
                revision: 0,
            },
            expires: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_secs()
                + 60,
        };
        assert!(apply(&state, &selection).await);
        // A repeated delivery observes the existing warm target; no restart.
        assert!(apply(&state, &selection).await);
        let axum::Json(view) = crate::playlist::get(axum::extract::State(state.clone()))
            .await
            .unwrap();
        let view = serde_json::to_value(view).unwrap();
        selection.edit = Some(json!({"expected":view["playlist"],"from":0,"remove":true}));
        assert!(apply(&state, &selection).await);
        // A stale retry must not remove a different entry.
        assert!(!apply(&state, &selection).await);
        selection.edit = None;
        state.lock().unwrap().link_revisions.insert(player, 1);
        assert!(!apply(&state, &selection).await);
        selection.seat.revision = 1;
        selection.game = "not-on-host".into();
        assert!(!apply(&state, &selection).await);
        selection.game = "target".into();
        selection.expires = 0;
        assert!(!apply(&state, &selection).await);
        server.abort();
    }
}
