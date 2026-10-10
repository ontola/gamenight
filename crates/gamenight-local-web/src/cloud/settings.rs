//! Typed settings adapter. No model output becomes code or process arguments.
use super::{discovery::Selection, Seat};
use crate::{daemon, SharedState};
use futures_util::{SinkExt, StreamExt};
use gamenight_protocol::{
    ClientMessage, GameId, PartySnapshot, PlayerId, Role, ServerMessage, SessionId, SettingKind,
    SettingValue, SettingsAction,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use tokio_tungstenite::tungstenite::Message;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Command {
    pub action: SettingsAction,
    pub instance: SessionId,
    pub expected_revision: u64,
    #[serde(default)]
    pub values: BTreeMap<String, SettingValue>,
}
pub(crate) fn controls(party: &PartySnapshot) -> Option<Value> {
    controls_for(party, None)
}

/// Like [`controls`], for `game` when it is being played or warmed up, so a
/// phone can set up the next game before it starts.
pub(crate) fn controls_for(party: &PartySnapshot, game: Option<&str>) -> Option<Value> {
    let session = match game {
        None => party
            .active_session
            .as_ref()
            .or(party.warm_session.as_ref())?,
        Some(game) => party
            .active_session
            .iter()
            .chain(party.warm_session.iter())
            .find(|s| s.game.0 == game)?,
    };
    if !party.connected_games.contains(&session.game) {
        return None;
    }
    let entry = party.settings.iter().find(|s| s.game == session.game)?;
    if entry.specs.is_empty() {
        return None;
    }
    let mut settings = serde_json::Map::new();
    for spec in &entry.specs {
        let mut item = json!({"label":spec.label,"description":spec.description.clone().unwrap_or_default(),
            "value":entry.values.get(&spec.key)?,"applies":"See game description"});
        match &spec.kind {
            SettingKind::Number { min, max, .. } => {
                item["kind"] = json!("number");
                item["min"] = json!(min);
                item["max"] = json!(max);
                item["integer"] = json!(true);
            }
            SettingKind::Toggle { .. } => {
                item["kind"] = json!("toggle");
            }
            SettingKind::Choice { options, .. } => {
                item["kind"] = json!("choice");
                item["options"] = json!(options);
            }
        }
        settings.insert(spec.key.clone(), item);
    }
    Some(
        json!({"game":session.game,"instance":session.id,"revision":entry.revision,
        "can_undo":entry.can_undo,"settings":settings}),
    )
}

pub(crate) async fn apply(state: &SharedState, selection: &Selection) -> Result<(), String> {
    let command = selection
        .command
        .as_ref()
        .ok_or("Missing settings command")?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    if selection.expires <= now {
        return Err("Request expired".into());
    }
    control(state, &selection.seat, Some(&selection.game), command).await
}

/// Sends `command` to the daemon as the player seated at `seat` and waits
/// for its receipt. `game` defaults to the game whose active or warm session
/// is `command.instance`, for callers that only know the session.
pub(crate) async fn control(
    state: &SharedState,
    seat: &Seat,
    game: Option<&str>,
    command: &Command,
) -> Result<(), String> {
    let player = PlayerId(uuid::Uuid::parse_str(&seat.player).map_err(|_| "Invalid player")?);
    let addr = {
        let local = state.lock().unwrap();
        if *local.link_revisions.get(&player).unwrap_or(&0) != seat.revision {
            return Err("Player link changed".into());
        }
        local.daemon_addr.clone()
    };
    tokio::time::timeout(daemon::REPLY_TIMEOUT * 3, async {
        let (mut ws, _) = tokio_tungstenite::connect_async(format!("ws://{addr}"))
            .await
            .map_err(|_| "Host unavailable")?;
        ws.send(Message::Text(
            ClientMessage::Hello {
                role: Role::Overlay,
                game: None,
                token: None,
            }
            .to_json(),
        ))
        .await
        .map_err(|_| "Host disconnected")?;
        let party = daemon::read_welcome(&mut ws)
            .await
            .map_err(|_| "Host did not reply")?;
        if !party
            .seats
            .iter()
            .any(|s| s.index == seat.index && s.occupant.player_id() == Some(player))
        {
            return Err("Player left or changed seat".to_string());
        }
        let game = match game {
            Some(game) => GameId(game.to_string()),
            None => party
                .active_session
                .iter()
                .chain(party.warm_session.iter())
                .find(|s| s.id == command.instance)
                .map(|s| s.game.clone())
                .ok_or("That game is no longer running")?,
        };
        ws.send(Message::Text(
            ClientMessage::ControlSettings {
                game: game.clone(),
                session: command.instance,
                expected_revision: command.expected_revision,
                player_id: player,
                action: command.action,
                values: command.values.clone(),
            }
            .to_json(),
        ))
        .await
        .map_err(|_| "Host disconnected")?;
        while let Some(Ok(Message::Text(text))) = ws.next().await {
            match serde_json::from_str::<ServerMessage>(&text) {
                Ok(ServerMessage::Error { message }) => return Err(message),
                Ok(ServerMessage::SettingsAccepted {
                    game: accepted,
                    session,
                    revision,
                }) if accepted == game
                    && session == command.instance
                    && revision == command.expected_revision + 1 =>
                {
                    let _ = ws.close(None).await;
                    return Ok(());
                }
                _ => {}
            }
        }
        Err("Host disconnected before confirming settings".into())
    })
    .await
    .map_err(|_| "Host confirmation timed out".to_string())?
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ServerState;
    use std::sync::{Arc, Mutex};

    #[tokio::test]
    async fn desktop_bridge_confirms_typed_changes_and_refuses_stale_identity() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap().to_string();
        let server = tokio::spawn(gamenight_daemon::run_with_library(
            listener,
            vec![serde_json::from_value(json!({"id":"test","title":"Test"})).unwrap()],
        ));
        let state = Arc::new(Mutex::new(ServerState::new(addr.clone())));
        let (mut game, _) = tokio_tungstenite::connect_async(format!("ws://{addr}"))
            .await
            .unwrap();
        game.send(Message::Text(
            json!({"type":"hello","role":"game","game":"test"}).to_string(),
        ))
        .await
        .unwrap();
        daemon::read_welcome(&mut game).await.unwrap();
        game.send(Message::Text(json!({"type":"declare_settings","settings":[
            {"key":"items","label":"Items","kind":"toggle","default":true},
            {"key":"arena","label":"Arena","kind":"choice","options":["earth","moon"],"default":"earth"}
        ]}).to_string())).await.unwrap();
        let (mut overlay, _) = tokio_tungstenite::connect_async(format!("ws://{addr}"))
            .await
            .unwrap();
        overlay
            .send(Message::Text(
                json!({"type":"hello","role":"overlay"}).to_string(),
            ))
            .await
            .unwrap();
        daemon::read_welcome(&mut overlay).await.unwrap();
        overlay
            .send(Message::Text(
                json!({"type":"join_party","name":"Test","seat":0}).to_string(),
            ))
            .await
            .unwrap();
        let player = daemon::wait_for_new_player(&mut overlay, &Default::default())
            .await
            .unwrap();
        let (mut observer, _) = tokio_tungstenite::connect_async(format!("ws://{addr}"))
            .await
            .unwrap();
        observer
            .send(Message::Text(
                json!({"type":"hello","role":"overlay"}).to_string(),
            ))
            .await
            .unwrap();
        let party = daemon::read_welcome(&mut observer).await.unwrap();
        let advertised = controls(&party).unwrap();
        assert_eq!(advertised["settings"]["items"]["kind"], "toggle");
        assert_eq!(
            advertised["settings"]["arena"]["options"],
            json!(["earth", "moon"])
        );
        let mut selection=Selection {
            edit:None,start:false,id:"batch".into(),game:"test".into(),
            seat:Seat {index:0,player:player.0.to_string(),revision:0},
            expires:std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs()+60,
            command:Some(serde_json::from_value(json!({"action":"set","instance":advertised["instance"],
                "expected_revision":advertised["revision"],"values":{"items":false,"arena":"moon"}})).unwrap()),
        };
        apply(&state, &selection).await.unwrap();
        assert!(apply(&state, &selection).await.is_err(), "stale batch");
        selection.command.as_mut().unwrap().expected_revision += 1;
        selection
            .command
            .as_mut()
            .unwrap()
            .values
            .insert("arena".into(), SettingValue::Choice("invalid".into()));
        assert!(apply(&state, &selection).await.is_err(), "invalid choice");
        selection.command.as_mut().unwrap().action = SettingsAction::Undo;
        selection.command.as_mut().unwrap().values.clear();
        apply(&state, &selection).await.unwrap();
        selection.command.as_mut().unwrap().expected_revision += 1;
        state.lock().unwrap().link_revisions.insert(player, 1);
        assert!(apply(&state, &selection)
            .await
            .unwrap_err()
            .contains("link"));
        selection.seat.revision = 1;
        selection.expires = 0;
        assert!(apply(&state, &selection)
            .await
            .unwrap_err()
            .contains("expired"));
        server.abort();
    }
}
