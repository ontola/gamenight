//! Local party controls; only public playlist metadata crosses HTTP.
use crate::{
    daemon::{read_welcome, REPLY_TIMEOUT},
    SharedState,
};
use axum::{extract::State, http::StatusCode, Json};
use futures_util::{SinkExt, StreamExt};
use gamenight_protocol::{ClientMessage, PartySnapshot, PlaylistSnapshot, Role, ServerMessage};
use serde::{Deserialize, Serialize};
use tokio_tungstenite::tungstenite::Message;

#[derive(Deserialize)]
pub(crate) struct MoveRequest {
    expected: PlaylistSnapshot,
    from: usize,
    #[serde(default)]
    to: Option<usize>,
    #[serde(default)]
    remove: bool,
}
#[derive(Serialize)]
pub(crate) struct View {
    playlist: PlaylistSnapshot,
    playing: Option<gamenight_protocol::GameId>,
    next: Option<gamenight_protocol::GameId>,
}
impl From<PartySnapshot> for View {
    fn from(party: PartySnapshot) -> Self {
        Self {
            playlist: party.playlist,
            playing: party.active_session.map(|s| s.game),
            next: party
                .warm_session
                .map(|s| s.game)
                .or_else(|| party.warming.map(|e| e.game)),
        }
    }
}
pub(crate) async fn get(State(state): State<SharedState>) -> Result<Json<View>, StatusCode> {
    exchange(state, None).await
}
pub(crate) async fn move_entry(
    State(state): State<SharedState>,
    Json(request): Json<MoveRequest>,
) -> Result<Json<View>, StatusCode> {
    exchange(state, Some(request)).await
}
async fn exchange(
    state: SharedState,
    request: Option<MoveRequest>,
) -> Result<Json<View>, StatusCode> {
    let addr = state.lock().unwrap().daemon_addr.clone();
    tokio::time::timeout(REPLY_TIMEOUT * 3, async {
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
        let party = read_welcome(&mut ws).await.map_err(StatusCode::from)?;
        let Some(request) = request else {
            return Ok(Json(party.into()));
        };
        if party.playlist != request.expected {
            return Err(StatusCode::CONFLICT);
        }
        if request.remove == request.to.is_some()
            || request.from >= request.expected.entries.len()
            || request
                .to
                .is_some_and(|to| to >= request.expected.entries.len())
        {
            return Err(StatusCode::BAD_REQUEST);
        }
        let mut target = request.expected.entries.clone();
        let moved = target.remove(request.from);
        let command = if let Some(to) = request.to {
            target.insert(to, moved);
            ClientMessage::MovePlaylistEntry {
                expected: request.expected,
                from: request.from,
                to,
            }
        } else {
            ClientMessage::RemovePlaylistEntry {
                expected: request.expected,
                index: request.from,
            }
        };
        ws.send(Message::Text(command.to_json()))
            .await
            .map_err(|_| StatusCode::BAD_GATEWAY)?;
        while let Some(message) = ws.next().await {
            if let Message::Text(text) = message.map_err(|_| StatusCode::BAD_GATEWAY)? {
                match serde_json::from_str::<ServerMessage>(&text)
                    .map_err(|_| StatusCode::BAD_GATEWAY)?
                {
                    ServerMessage::PartyState { party } if party.playlist.entries == target => {
                        return Ok(Json(party.into()))
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
}

#[cfg(test)]
mod tests {
    use super::*;
    use gamenight_protocol::{GameId, SessionId, SessionInfo, SessionPhase};

    #[test]
    fn ready_game_stays_up_next_after_warming_metadata_disappears() {
        let mut party = gamenight_core::GameNight::default().snapshot();
        party.warm_session = Some(SessionInfo {
            id: SessionId::new(),
            game: GameId::new("tank"),
            phase: SessionPhase::Ready,
            progress: None,
            progress_label: None,
        });
        assert!(party.warming.is_none());
        assert_eq!(View::from(party).next, Some(GameId::new("tank")));
    }
}
