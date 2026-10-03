//! Optional outbound profile and discovery relay. Offline studios never require cloud availability.
pub(crate) mod discovery;
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
pub(crate) struct Seat {
    pub(crate) index: u8,
    pub(crate) player: String,
    pub(crate) revision: u64,
}
#[derive(Clone)]
pub(crate) struct Bridge {
    origin: String,
    http: reqwest::Client,
    session: Arc<Mutex<Option<String>>>,
    seats: Arc<Mutex<Vec<Seat>>>,
    waiting: Arc<Mutex<serde_json::Value>>,
    pairing: Arc<Mutex<HashMap<String, CachedPairing>>>,
    pairing_request: Arc<tokio::sync::Mutex<()>>,
}
#[derive(Clone)]
struct CachedPairing {
    seat: Seat,
    url: String,
    created: std::time::Instant,
}

#[cfg(test)]
mod pairing_tests {
    use super::*;

    #[tokio::test]
    async fn cached_ticket_is_stable_but_expires_and_tracks_seat_identity() {
        let seat = Seat {
            index: 0,
            player: "player-a".into(),
            revision: 1,
        };
        // No network server: a valid cached ticket must not send a request.
        let bridge = Bridge {
            origin: "https://gamenight.invalid".into(),
            http: reqwest::Client::new(),
            session: Arc::default(),
            seats: Arc::new(Mutex::new(vec![seat.clone()])),
            waiting: Arc::default(),
            pairing: Arc::new(Mutex::new(HashMap::from([(
                seat.player.clone(),
                CachedPairing {
                    seat: seat.clone(),
                    url: "https://gamenight.invalid/studio#pair=stable".into(),
                    created: std::time::Instant::now(),
                },
            )]))),
            pairing_request: Arc::default(),
        };
        let query = HashMap::from([("claim".into(), seat.player.clone())]);
        let first = bridge.pairing_url(&query).await.unwrap();
        assert_eq!(
            bridge.pairing_url(&query).await.as_deref(),
            Some(first.as_str())
        );
        bridge.seats.lock().unwrap()[0].revision += 1;
        assert!(bridge.pairing_urls().is_empty());
        assert!(bridge.pairing_url(&query).await.is_none());
        bridge.seats.lock().unwrap()[0] = seat.clone();
        bridge
            .pairing
            .lock()
            .unwrap()
            .get_mut(&seat.player)
            .unwrap()
            .created -= Duration::from_secs(241);
        assert!(bridge.pairing_urls().is_empty());
        assert!(bridge.pairing_url(&query).await.is_none());
    }
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
    #[serde(default)]
    selection: Option<discovery::Selection>,
    updates: Vec<Update>,
    #[serde(default)]
    pending: Vec<serde_json::Value>,
    #[serde(default)]
    room_code: String,
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
            pairing: Arc::default(),
            pairing_request: Arc::default(),
            waiting: Arc::new(Mutex::new(serde_json::json!({}))),
        })
    }
    pub fn waiting(&self) -> serde_json::Value {
        self.waiting.lock().unwrap().clone()
    }
    pub async fn pickup(
        &self,
        state: &SharedState,
        id: &str,
        player: PlayerId,
    ) -> axum::http::StatusCode {
        use axum::http::StatusCode;
        if state
            .lock()
            .unwrap()
            .bindings
            .values()
            .any(|p| *p == player)
        {
            return StatusCode::CONFLICT;
        }
        let Some((seats, _)) = self.snapshot(state).await else {
            return StatusCode::SERVICE_UNAVAILABLE;
        };
        let Some(seat) = seats.iter().find(|s| s.player == player.0.to_string()) else {
            return StatusCode::GONE;
        };
        let Some(token) = self.session.lock().unwrap().clone() else {
            return StatusCode::SERVICE_UNAVAILABLE;
        };
        match self
            .http
            .post(format!("{}/v1/lobbies/pickup", self.origin))
            .bearer_auth(token)
            .json(&serde_json::json!({"pending":id,"seat":seat}))
            .send()
            .await
        {
            Ok(r) => r.status(),
            Err(_) => StatusCode::BAD_GATEWAY,
        }
    }
    pub fn pairing_urls(&self) -> HashMap<String, String> {
        let seats = self.seats.lock().unwrap().clone();
        self.pairing
            .lock()
            .unwrap()
            .iter()
            .filter(|(_, p)| {
                seats.contains(&p.seat) && p.created.elapsed() < Duration::from_secs(240)
            })
            .map(|(id, p)| (id.clone(), p.url.clone()))
            .collect()
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
        let _guard = self.pairing_request.lock().await;
        if let Some(cached) = self.pairing.lock().ok()?.get(&seat.player) {
            if cached.seat == seat && cached.created.elapsed() < Duration::from_secs(240) {
                return Some(cached.url.clone());
            }
        }
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
        let url = format!("{}/studio#pair={}", self.origin, ticket.ticket);
        self.pairing.lock().ok()?.insert(
            seat.player.clone(),
            CachedPairing {
                seat,
                url: url.clone(),
                created: std::time::Instant::now(),
            },
        );
        Some(url)
    }
    async fn snapshot(
        &self,
        state: &SharedState,
    ) -> Option<(Vec<Seat>, gamenight_protocol::PartySnapshot)> {
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
        Some((
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
            party,
        ))
    }
    pub async fn run(self, state: SharedState) {
        let mut applied: HashMap<String, (Seat, u64)> = HashMap::new();
        let mut acknowledged: Option<String> = None;
        loop {
            tokio::time::sleep(Duration::from_secs(3)).await;
            let Some((seats, party)) = self.snapshot(&state).await else {
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
                acknowledged = None;
            }
            let Ok(response) = self
                .http
                .post(format!("{}/v1/lobbies/poll", self.origin))
                .bearer_auth(token.unwrap())
                .json(&serde_json::json!({"seats":seats,"discovery":discovery::snapshot(&party, &acknowledged)}))
                .send()
                .await
            else {
                continue;
            };
            if response.status() == 401 {
                *self.session.lock().unwrap() = None;
                self.pairing.lock().unwrap().clear();
                *self.waiting.lock().unwrap() = serde_json::json!({});
                continue;
            }
            if !response.status().is_success() {
                continue;
            }
            let Ok(updates) = response.json::<Updates>().await else {
                continue;
            };
            if let Some(selection) = &updates.selection {
                if acknowledged.as_ref() != Some(&selection.id)
                    && seats.contains(&selection.seat)
                    && updates.updates.iter().any(|u| u.seat == selection.seat)
                    && discovery::apply(&state, selection).await
                {
                    acknowledged = Some(selection.id.clone());
                }
            }
            self.pairing
                .lock()
                .unwrap()
                .retain(|_, p| seats.contains(&p.seat));
            for seat in &seats {
                let query = HashMap::from([("claim".into(), seat.player.clone())]);
                let _ = self.pairing_url(&query).await;
            }
            *self.waiting.lock().unwrap() =
                serde_json::json!({"room_code":updates.room_code,"pending":updates.pending});
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
                    if local
                        .bindings
                        .iter()
                        .any(|(bound, p)| *p == player && bound != &id)
                    {
                        *local.link_revisions.entry(player).or_default() += 1;
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
