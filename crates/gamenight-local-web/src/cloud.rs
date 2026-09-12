//! Optional outbound profile relay. Offline studios never require cloud availability.
use crate::{daemon, join_session, JoinSessionRequest, Profile, SharedState};
use axum::{
    extract::{Path, State},
    Json,
};
use futures_util::SinkExt;
use gamenight_protocol::{ClientMessage, PlayerId, Role};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::Duration,
};
#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
struct Seat {
    index: u8,
    player: String,
    revision: u64,
}
#[derive(Clone)]
pub(crate) struct Bridge {
    origin: String,
    http: reqwest::Client,
    session: Arc<Mutex<Option<String>>>,
    seats: Arc<Mutex<Vec<Seat>>>,
}
#[derive(Deserialize)]
struct Registration {
    token: String,
}
#[derive(Deserialize)]
struct Ticket {
    ticket: String,
}
#[derive(Deserialize)]
struct Updates {
    updates: Vec<Update>,
}
#[derive(Deserialize)]
struct Update {
    seat: Seat,
    account: String,
    profile: CloudProfile,
    profile_revision: u64,
}
#[derive(Deserialize)]
struct CloudProfile {
    display_name: String,
    skin_color: String,
    avatar: String,
}
impl Bridge {
    pub fn configured() -> Option<Self> {
        let origin = std::env::var("GAMENIGHT_CLOUD_URL").ok()?;
        let u = reqwest::Url::parse(&origin).ok()?;
        if u.scheme() != "https"
            || u.path() != "/"
            || u.query().is_some()
            || u.fragment().is_some()
            || !u.username().is_empty()
            || u.password().is_some()
        {
            tracing::warn!("Cloud profile sync requires an HTTPS origin");
            return None;
        }
        Some(Self {
            origin: origin.trim_end_matches('/').into(),
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(10))
                .redirect(reqwest::redirect::Policy::none())
                .build()
                .ok()?,
            session: Arc::default(),
            seats: Arc::default(),
        })
    }
    pub async fn pairing_url(&self, query: &HashMap<String, String>) -> Option<String> {
        let seat = {
            let seats = self.seats.lock().ok()?;
            if let Some(index) = query.get("seat").and_then(|s| s.parse::<u8>().ok()) {
                seats.iter().find(|s| s.index == index).cloned()
            } else {
                let player = query.get("claim")?;
                seats.iter().find(|s| &s.player == player).cloned()
            }
        }?;
        let token = self.session.lock().ok()?.clone()?;
        let response = self
            .http
            .post(format!("{}/v1/lobbies/ticket", self.origin))
            .bearer_auth(token)
            .json(&serde_json::json!({"index":seat.index}))
            .send()
            .await
            .ok()?;
        if !response.status().is_success() {
            return None;
        }
        let ticket: Ticket = response.json().await.ok()?;
        Some(format!("{}/studio#pair={}", self.origin, ticket.ticket))
    }
    async fn snapshot(&self, state: &SharedState) -> Option<Vec<Seat>> {
        let addr = state.lock().ok()?.daemon_addr.clone();
        let (mut ws, _) = tokio::time::timeout(
            Duration::from_secs(3),
            tokio_tungstenite::connect_async(format!("ws://{addr}")),
        )
        .await
        .ok()?
        .ok()?;
        ws.send(tokio_tungstenite::tungstenite::Message::Text(
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
        let _ = ws.close(None).await;
        let local = state.lock().ok()?;
        Some(
            party
                .seats
                .iter()
                .filter_map(|s| {
                    s.occupant.player_id().map(|id| Seat {
                        index: s.index,
                        player: id.0.to_string(),
                        revision: *local.link_revisions.get(&id).unwrap_or(&0),
                    })
                })
                .collect(),
        )
    }
    pub async fn run(self, state: SharedState) {
        let mut applied: HashMap<String, (Seat, u64)> = HashMap::new();
        loop {
            tokio::time::sleep(Duration::from_secs(3)).await;
            let Some(seats) = self.snapshot(&state).await else {
                continue;
            };
            *self.seats.lock().unwrap() = seats.clone();
            let mut token = self.session.lock().unwrap().clone();
            if token.is_none() {
                let Ok(response) = self
                    .http
                    .post(format!("{}/v1/lobbies/register", self.origin))
                    .send()
                    .await
                else {
                    continue;
                };
                if !response.status().is_success() {
                    tokio::time::sleep(Duration::from_secs(30)).await;
                    continue;
                }
                let Ok(reg) = response.json::<Registration>().await else {
                    continue;
                };
                token = Some(reg.token);
                *self.session.lock().unwrap() = token.clone();
                applied.clear();
            }
            let Ok(response) = self
                .http
                .post(format!("{}/v1/lobbies/poll", self.origin))
                .bearer_auth(token.unwrap())
                .json(&serde_json::json!({"seats":seats}))
                .send()
                .await
            else {
                continue;
            };
            if response.status() == 401 {
                *self.session.lock().unwrap() = None;
                continue;
            }
            if !response.status().is_success() {
                continue;
            }
            let Ok(updates) = response.json::<Updates>().await else {
                continue;
            };
            {
                let mut local = state.lock().unwrap();
                let retired: Vec<_> = applied
                    .keys()
                    .filter(|account| !updates.updates.iter().any(|u| &u.account == *account))
                    .cloned()
                    .collect();
                for account in retired {
                    if let Some(player) = local.bindings.remove(&format!("cloud_{account}")) {
                        *local.link_revisions.entry(player).or_default() += 1;
                    }
                }
            }
            applied.retain(|account, _| updates.updates.iter().any(|u| &u.account == account));
            for u in updates.updates {
                if !seats.contains(&u.seat)
                    || applied.get(&u.account) == Some(&(u.seat.clone(), u.profile_revision))
                {
                    continue;
                }
                let Ok(uuid) = uuid::Uuid::parse_str(&u.seat.player) else {
                    continue;
                };
                let player = PlayerId(uuid);
                let id = format!("cloud_{}", u.account);
                {
                    let mut local = state.lock().unwrap();
                    if *local.link_revisions.get(&player).unwrap_or(&0) != u.seat.revision {
                        continue;
                    }
                    if local.bindings.get(&id).is_some_and(|old| *old != player) {
                        local.bindings.remove(&id);
                    }
                    local.profiles.insert(
                        id.clone(),
                        Profile {
                            id: id.clone(),
                            username: u.profile.display_name,
                            skin_color: u.profile.skin_color,
                            avatar: u.profile.avatar,
                        },
                    );
                }
                let result = join_session(
                    Path(id),
                    State(state.clone()),
                    Json(JoinSessionRequest {
                        link_revision: u.seat.revision,
                        claim: Some(player),
                        seat: None,
                    }),
                )
                .await;
                if result.as_ref().is_ok_and(|response| {
                    response.0["status"] == "claimed" || response.0["status"] == "joined"
                }) {
                    applied.insert(u.account, (u.seat, u.profile_revision));
                }
            }
        }
    }
}
