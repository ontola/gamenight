//! Opt-in adapter for previewing a separately supplied catalog UI locally.
use crate::{
    cloud::{discovery, Seat},
    daemon, SharedState,
};
use axum::{
    extract::{Query, State},
    http::StatusCode,
    Json,
};
use futures_util::SinkExt;
use gamenight_protocol::{ClientMessage, PartySnapshot, Role};
use serde::Deserialize;
use serde_json::{json, Value};

#[derive(Deserialize)]
pub struct Request {
    #[serde(default)]
    profile: String,
    #[serde(default)]
    game: String,
    #[serde(default)]
    request_id: String,
}
async fn party(state: &SharedState) -> Result<PartySnapshot, StatusCode> {
    if std::env::var_os("GAMENIGHT_DEV_CATALOG_DIR").is_none() {
        return Err(StatusCode::NOT_FOUND);
    }
    let addr = state.lock().unwrap().daemon_addr.clone();
    tokio::time::timeout(daemon::REPLY_TIMEOUT, async {
        let (mut ws, _) = tokio_tungstenite::connect_async(format!("ws://{addr}"))
            .await
            .map_err(|_| StatusCode::BAD_GATEWAY)?;
        ws.send(tokio_tungstenite::tungstenite::Message::Text(
            ClientMessage::Hello {
                role: Role::Overlay,
                game: None,
                token: None,
            }
            .to_json(),
        ))
        .await
        .map_err(|_| StatusCode::BAD_GATEWAY)?;
        let result = daemon::read_welcome(&mut ws)
            .await
            .map_err(StatusCode::from);
        let _ = ws.close(None).await;
        result
    })
    .await
    .map_err(|_| StatusCode::GATEWAY_TIMEOUT)?
}
fn seat(state: &SharedState, party: &PartySnapshot, profile: &str) -> Option<Seat> {
    let local = state.lock().ok()?;
    let id = *local.bindings.get(profile)?;
    let seat = party
        .seats
        .iter()
        .find(|s| s.occupant.player_id() == Some(id))?;
    Some(Seat {
        index: seat.index,
        player: id.0.to_string(),
        revision: *local.link_revisions.get(&id).unwrap_or(&0),
    })
}
pub async fn status(
    State(state): State<SharedState>,
    Query(request): Query<Request>,
) -> Result<Json<Value>, StatusCode> {
    let party = party(&state).await?;
    if seat(&state, &party, &request.profile).is_none() {
        return Ok(Json(json!({"status":"none"})));
    }
    Ok(Json(
        json!({"status":"connected","room_code":"Local","players":party.seats.iter().filter(|s|s.occupant.player_id().is_some()).count(),"fresh":true,"discovery":discovery::snapshot(&party,&None)}),
    ))
}
pub async fn next(
    State(state): State<SharedState>,
    Json(request): Json<Request>,
) -> Result<Json<Value>, StatusCode> {
    let party = party(&state).await?;
    let seat = seat(&state, &party, &request.profile).ok_or(StatusCode::FORBIDDEN)?;
    let expires = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
        + 30;
    let selection = discovery::Selection {
        id: request.request_id,
        game: request.game,
        seat,
        expires,
        edit: None,
    };
    if !discovery::apply(&state, &selection).await {
        return Err(StatusCode::CONFLICT);
    }
    Ok(Json(json!({"selection":null})))
}
