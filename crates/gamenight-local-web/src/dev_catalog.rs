//! Opt-in adapter for previewing a separately supplied catalog UI locally.
use crate::{cloud::discovery, daemon, room_controls::seat, SharedState};
use axum::{
    extract::{Query, State},
    http::StatusCode,
    Json,
};
use gamenight_protocol::PartySnapshot;
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
    daemon::party(state).await
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
        command: None,
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
