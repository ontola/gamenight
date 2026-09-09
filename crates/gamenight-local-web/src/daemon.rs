//! Bounded reads at the HTTP-to-daemon boundary.
use futures_util::StreamExt;
use gamenight_protocol::{PartySnapshot, PlayerId, ServerMessage};
use std::{collections::HashSet, time::Duration};
use tokio_tungstenite::{tungstenite::Message, MaybeTlsStream, WebSocketStream};

pub(crate) const REPLY_TIMEOUT: Duration = Duration::from_secs(2);
type DaemonWs = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

#[derive(Debug)]
pub(crate) enum DaemonError {
    Timeout,
    Disconnected,
}

impl From<DaemonError> for axum::http::StatusCode {
    fn from(error: DaemonError) -> Self {
        match error {
            DaemonError::Timeout => Self::GATEWAY_TIMEOUT,
            DaemonError::Disconnected => Self::BAD_GATEWAY,
        }
    }
}

async fn read_matching<T>(
    ws: &mut DaemonWs,
    select: impl Fn(ServerMessage) -> Option<T>,
) -> Result<T, DaemonError> {
    tokio::time::timeout(REPLY_TIMEOUT, async {
        while let Some(message) = ws.next().await {
            match message.map_err(|_| DaemonError::Disconnected)? {
                Message::Text(text) => {
                    if let Ok(message) = serde_json::from_str(&text) {
                        if let Some(value) = select(message) {
                            return Ok(value);
                        }
                    }
                }
                Message::Close(_) => break,
                _ => {}
            }
        }
        Err(DaemonError::Disconnected)
    })
    .await
    .map_err(|_| DaemonError::Timeout)?
}

pub(crate) async fn read_welcome(ws: &mut DaemonWs) -> Result<PartySnapshot, DaemonError> {
    read_matching(ws, |message| match message {
        ServerMessage::Welcome { party, .. } => Some(party),
        _ => None,
    })
    .await
}

pub(crate) async fn wait_for_new_player(
    ws: &mut DaemonWs,
    existing: &HashSet<PlayerId>,
) -> Result<PlayerId, DaemonError> {
    read_matching(ws, |message| match message {
        ServerMessage::PartyState { party } => party
            .players
            .iter()
            .find(|player| !existing.contains(&player.id))
            .map(|player| player.id),
        _ => None,
    })
    .await
}
