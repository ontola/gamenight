//! Tells the daemon which players have a linked phone, so it can count
//! phones for games played on them (`PlayWith`). The bindings live here,
//! whichever way a phone joined (LAN or cloud); the daemon only sees players.
use crate::SharedState;
use futures_util::SinkExt;
use gamenight_protocol::{ClientMessage, PartySnapshot, PlayerId};
use std::time::Duration;
use tokio_tungstenite::tungstenite::Message;

/// The linked phones of seated players, in the order the daemon keeps them.
pub(crate) fn linked(state: &SharedState, party: &PartySnapshot) -> Vec<PlayerId> {
    let local = state.lock().unwrap();
    let mut phones: Vec<_> = local
        .bindings
        .values()
        .filter(|id| party.players.iter().any(|p| p.id == **id))
        .copied()
        .collect();
    phones.sort_by_key(|p| p.0);
    phones.dedup();
    phones
}

/// How long a phone player's phone may be gone before the player leaves.
/// Long enough for a phone that is moved to another seat or room link.
const PHONE_GONE: Duration = Duration::from_secs(10);

/// Phone players whose phone left the room (unlinked, left, expired) for
/// longer than [`PHONE_GONE`]. They have no controller, so nothing else
/// would ever take them out of the party.
fn abandoned(
    state: &SharedState,
    present: &[PlayerId],
    gone: &mut std::collections::HashMap<PlayerId, std::time::Instant>,
) -> Vec<PlayerId> {
    let mut local = state.lock().unwrap();
    let crate::ServerState {
        phone_players,
        bindings,
        ..
    } = &mut *local;
    phone_players.retain(|id, _| present.contains(id));
    gone.retain(|id, _| phone_players.contains_key(id));
    let mut leaving = vec![];
    for (id, linked_once) in phone_players.iter_mut() {
        if bindings.values().any(|p| p == id) {
            *linked_once = true;
            gone.remove(id);
        } else if *linked_once
            && gone
                .entry(*id)
                .or_insert_with(std::time::Instant::now)
                .elapsed()
                >= PHONE_GONE
        {
            leaving.push(*id);
        }
    }
    for id in &leaving {
        phone_players.remove(id);
        gone.remove(id);
    }
    leaving
}

/// Compares bindings with the party once a second and corrects the daemon
/// when they differ. Comparing against the party, not the last send, also
/// covers a restarted daemon.
pub async fn watch(state: SharedState) {
    let hub = state.lock().unwrap().companions.clone();
    let mut tick = tokio::time::interval(Duration::from_secs(1));
    let mut gone = std::collections::HashMap::new();
    loop {
        tick.tick().await;
        let Some(party) = hub.party() else { continue };
        let present: Vec<_> = party.players.iter().map(|p| p.id).collect();
        for player in abandoned(&state, &present, &mut gone) {
            tracing::info!(?player, "phone left the room, its player leaves the party");
            remove(&state, player).await;
        }
        let phones = linked(&state, &party);
        if phones == party.phones {
            continue;
        }
        if let Err(status) = send(&state, phones).await {
            tracing::debug!(%status, "could not report linked phones");
        }
    }
}

async fn send(state: &SharedState, players: Vec<PlayerId>) -> Result<(), axum::http::StatusCode> {
    let (mut ws, _) = crate::daemon::connect(state).await?;
    ws.send(Message::Text(
        ClientMessage::SetPhones {
            players: players.clone(),
        }
        .to_json(),
    ))
    .await
    .map_err(|_| axum::http::StatusCode::BAD_GATEWAY)?;
    let acknowledged = crate::daemon::wait_for_phones(&mut ws, &players).await;
    let _ = ws.close(None).await;
    acknowledged.map_err(axum::http::StatusCode::from)
}

/// Seats a phone waiting at the LAN door as a player of its own, holding no
/// controller, then links it like a controller pickup would.
pub(crate) async fn seat_waiting(
    state: &SharedState,
    pending: &str,
    profile: &serde_json::Value,
) -> axum::http::StatusCode {
    let player = match create(state, profile).await {
        Ok(player) => player,
        Err(status) => return status,
    };
    let status = crate::local_room::pickup(state, pending, player).await;
    if !status.is_success() {
        tracing::info!(%status, "phone seat not linked, removing it again");
        remove(state, player).await;
    }
    status
}

/// Adds a phone-only player for a waiting entry's profile
/// (`display_name`, `preferred_color`, `avatar`).
pub(crate) async fn create(
    state: &SharedState,
    profile: &serde_json::Value,
) -> Result<PlayerId, axum::http::StatusCode> {
    let text = |key: &str| {
        profile[key]
            .as_str()
            .filter(|s| !s.is_empty())
            .map(String::from)
    };
    let (mut ws, party) = crate::daemon::connect(state).await?;
    let existing = party.players.iter().map(|p| p.id).collect();
    ws.send(Message::Text(
        ClientMessage::JoinPhonePlayer {
            name: text("display_name").unwrap_or_else(|| "Player".into()),
            color: text("preferred_color"),
            avatar: text("avatar"),
        }
        .to_json(),
    ))
    .await
    .map_err(|_| axum::http::StatusCode::BAD_GATEWAY)?;
    let player = crate::daemon::wait_for_new_player(&mut ws, &existing).await;
    let _ = ws.close(None).await;
    let player = player.map_err(axum::http::StatusCode::from)?;
    state.lock().unwrap().phone_players.insert(player, false);
    Ok(player)
}

/// Takes a phone-only player out again when its phone never linked.
pub(crate) async fn remove(state: &SharedState, player_id: PlayerId) {
    let Ok((mut ws, _)) = crate::daemon::connect(state).await else {
        return;
    };
    let _ = ws
        .send(Message::Text(
            ClientMessage::LeaveParty { player_id }.to_json(),
        ))
        .await;
    let _ = ws.close(None).await;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_phone_player_leaves_only_after_its_linked_phone_is_gone_a_while() {
        let state = std::sync::Arc::new(std::sync::Mutex::new(crate::ServerState::new(
            "127.0.0.1:1".into(),
        )));
        let player = PlayerId(uuid::Uuid::new_v4());
        let party = [player];
        let mut gone = std::collections::HashMap::new();
        state.lock().unwrap().phone_players.insert(player, false);
        // Not linked yet: a new phone seat waits for its pickup.
        assert!(abandoned(&state, &party, &mut gone).is_empty());
        assert!(gone.is_empty());
        state
            .lock()
            .unwrap()
            .bindings
            .insert("phone".into(), player);
        assert!(abandoned(&state, &party, &mut gone).is_empty());
        state.lock().unwrap().bindings.clear();
        assert!(abandoned(&state, &party, &mut gone).is_empty(), "grace");
        *gone.get_mut(&player).unwrap() -= PHONE_GONE;
        assert_eq!(abandoned(&state, &party, &mut gone), vec![player]);
        assert!(state.lock().unwrap().phone_players.is_empty());
    }
}
