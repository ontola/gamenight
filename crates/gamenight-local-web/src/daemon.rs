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

/// A socket flush is not an acknowledgement: a closing websocket may stop the
/// daemon reader after the first command. Observe the complete profile before
/// reporting a pickup/save as successful.
pub(crate) async fn wait_for_profile(
    ws: &mut DaemonWs,
    id: PlayerId,
    profile: &crate::Profile,
) -> Result<(), DaemonError> {
    read_matching(ws, |message| match message {
        ServerMessage::PartyState { party } => party
            .players
            .iter()
            .any(|player| {
                player.id == id
                    && player.name == profile.username
                    && player.avatar.as_deref().unwrap_or("") == profile.avatar
                    && player.skin_color.as_deref() == Some(profile.skin_color.as_str())
            })
            .then_some(()),
        _ => None,
    })
    .await
}
