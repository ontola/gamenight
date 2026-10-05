//! Typed settings adapter. No model output becomes code or process arguments.
use super::discovery::Selection;
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
    controls_for(party, false)
}

pub(crate) fn next_controls(party: &PartySnapshot) -> Option<Value> {
    let warm = party.warm_session.as_ref()?;
    if party
        .active_session
        .as_ref()
        .is_none_or(|active| active.id == warm.id)
    {
        return None;
    }
    if party.warming.as_ref().is_some_and(|s| s.game != warm.game) {
        return None;
    }
    controls_for(party, true)
}

fn controls_for(party: &PartySnapshot, upcoming: bool) -> Option<Value> {
    let session = if upcoming {
        party.warm_session.as_ref()?
    } else {
        party
            .active_session
            .as_ref()
            .or(party.warm_session.as_ref())?
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
    let player =
        PlayerId(uuid::Uuid::parse_str(&selection.seat.player).map_err(|_| "Invalid player")?);
    let addr = {
        let local = state.lock().unwrap();
        if *local.link_revisions.get(&player).unwrap_or(&0) != selection.seat.revision {
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
            .any(|s| s.index == selection.seat.index && s.occupant.player_id() == Some(player))
        {
            return Err("Player left or changed seat".to_string());
        }
        ws.send(Message::Text(
            ClientMessage::ControlSettings {
                game: GameId(selection.game.clone()),
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
                    game,
                    session,
                    revision,
                }) if game.0 == selection.game
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
    use super::super::Seat;
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
        let mut upcoming_party = party.clone();
        let active = upcoming_party.warm_session.clone().unwrap();
        let mut upcoming = active.clone();
        upcoming.id = SessionId(uuid::Uuid::new_v4());
        upcoming.game = GameId("next".into());
        upcoming_party.active_session = Some(active.clone());
        upcoming_party.warm_session = Some(upcoming.clone());
        upcoming_party.connected_games.push(upcoming.game.clone());
        let mut upcoming_settings = upcoming_party.settings[0].clone();
        upcoming_settings.game = upcoming.game.clone();
        upcoming_party.settings.push(upcoming_settings);
        assert_eq!(
            controls(&upcoming_party).unwrap()["instance"],
            json!(active.id)
        );
        assert_eq!(
            next_controls(&upcoming_party).unwrap()["instance"],
            json!(upcoming.id)
        );
        upcoming_party.warm_session = None;
        assert!(next_controls(&upcoming_party).is_none());
        let mut selection=Selection {
            edit:None,id:"batch".into(),game:"test".into(),
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
