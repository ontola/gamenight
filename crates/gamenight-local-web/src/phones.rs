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

/// Compares bindings with the party once a second and corrects the daemon
/// when they differ. Comparing against the party, not the last send, also
/// covers a restarted daemon.
pub async fn watch(state: SharedState) {
    let hub = state.lock().unwrap().companions.clone();
    let mut tick = tokio::time::interval(Duration::from_secs(1));
    loop {
        tick.tick().await;
        let Some(party) = hub.party() else { continue };
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
    player.map_err(axum::http::StatusCode::from)
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
