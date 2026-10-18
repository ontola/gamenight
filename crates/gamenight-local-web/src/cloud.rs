//! Optional outbound profile and discovery relay. Offline studios never require cloud availability.
mod companion;
pub(crate) mod discovery;
pub(crate) mod settings;
use crate::{daemon, join_session, JoinSessionRequest, Profile, SharedState};
use axum::{
    extract::{Path, State},
    Json,
};
use futures_util::SinkExt;
use gamenight_protocol::{ClientMessage, PlayerId, Role};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashMap},
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
    refresh: Arc<tokio::sync::Notify>,
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
            refresh: Arc::default(),
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
    /// Download grants (game id to token) for paid games someone seated
    /// owns: the complete current set. Secrets: never log them.
    #[serde(default)]
    grants: BTreeMap<String, String>,
    /// Preview builds this table may play because someone seated owns or
    /// tests the game. Each carries a secret grant: never log them.
    #[serde(default)]
    playtests: Vec<gamenight_protocol::Playtest>,
}
/// What a playtest announcement says, without its short-lived grant.
type PlaytestKey = Vec<(serde_json::Value, BTreeMap<String, String>)>;
fn playtest_key(playtests: &[gamenight_protocol::Playtest]) -> PlaytestKey {
    playtests
        .iter()
        .map(|p| (p.entry.clone(), p.versions.clone()))
        .collect()
}
/// Resend unchanged playtests this often, so a failed download retries with a
/// fresh grant.
const PLAYTEST_RESEND: Duration = Duration::from_secs(300);
#[derive(Deserialize)]
struct Update {
    seat: Seat,
    account: String,
    profile: CloudProfile,
    profile_revision: u64,
}
#[derive(Deserialize)]
struct CloudProfile {
    #[serde(default)]
    preferred_color: Option<String>,
    display_name: String,
    skin_color: String,
    avatar: String,
}
fn service_origin(configured: Option<&str>, offline: bool) -> Option<String> {
    if offline {
        return None;
    }
    let origin = configured.unwrap_or("https://gamenight.ontola.io");
    let url = reqwest::Url::parse(origin).ok()?;
    if url.scheme() != "https"
        || url.host_str().is_none()
        || url.path() != "/"
        || url.query().is_some()
        || url.fragment().is_some()
        || !url.username().is_empty()
        || url.password().is_some()
    {
        tracing::warn!("Cloud profile sync requires an HTTPS origin");
        return None;
    }
    Some(origin.trim_end_matches('/').into())
}

#[cfg(test)]
mod configuration_tests {
    use super::*;

    #[test]
    fn website_downloads_use_central_service_and_offline_is_explicit() {
        assert_eq!(
            service_origin(None, false).as_deref(),
            Some("https://gamenight.ontola.io")
        );
        assert_eq!(service_origin(None, true), None);
        assert_eq!(
            service_origin(Some("https://preview.example/"), false).as_deref(),
            Some("https://preview.example")
        );
        assert_eq!(service_origin(Some("https://preview.example/"), true), None);
        for bad in [
            "",
            "http://192.168.0.85:7913",
            "https://example/studio",
            "https://user:secret@example",
            "https://example/?r=test",
            "https://example/#pair=secret",
        ] {
            assert!(service_origin(Some(bad), false).is_none());
        }
    }
}

impl Bridge {
    pub fn configured() -> Option<Self> {
        let origin = service_origin(
            std::env::var("GAMENIGHT_CLOUD_URL").ok().as_deref(),
            std::env::var("GAMENIGHT_OFFLINE").as_deref() == Ok("1"),
        )?;
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
            refresh: Arc::default(),
            waiting: Arc::new(Mutex::new(serde_json::json!({}))),
        })
    }
    pub fn origin(&self) -> &str {
        &self.origin
    }

    /// The cloud room this host holds, so a restart can keep it.
    pub fn session_token(&self) -> Option<String> {
        self.session.lock().unwrap().clone()
    }
    /// Continue a room registered by the previous process. The cloud keeps a
    /// room for a short while without polls, so the code and phones stay.
    pub fn resume_session(&self, token: String) {
        *self.session.lock().unwrap() = Some(token);
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
            Ok(r) => {
                if r.status().is_success() {
                    // The server has accepted the claim. Fetch its authoritative
                    // account/revision now instead of waiting for the heartbeat.
                    self.refresh.notify_one();
                }
                r.status()
            }
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
        tokio::spawn(companion::run(self.clone(), state.clone()));
        let mut applied: HashMap<String, (Seat, u64)> = HashMap::new();
        let mut acknowledged: Option<String> = None;
        let mut receipt: Option<serde_json::Value> = None;
        // What the daemon last accepted; resent only when the set changes.
        let mut delivered_grants: Option<BTreeMap<String, String>> = None;
        let mut delivered_playtests: Option<(PlaytestKey, std::time::Instant)> = None;
        // Waiting phones that asked for a seat of their own, tried once each.
        let mut phone_seats: HashMap<String, Option<PlayerId>> = HashMap::new();
        loop {
            tokio::select! {
                _ = tokio::time::sleep(Duration::from_secs(3)) => {},
                _ = self.refresh.notified() => {},
            }
            let Some((seats, party)) = self.snapshot(&state).await else {
                continue;
            };
            *self.seats.lock().unwrap() = seats.clone();
            let mut token = self.session.lock().unwrap().clone();
            if token.is_none() {
                let Ok(response) = self
                    .http
                    .post(format!("{}/v1/lobbies/register", self.origin))
                    .json(&serde_json::json!({"device":state.lock().unwrap().memory.device}))
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
                receipt = None;
            }
            let mut discovery = discovery::snapshot(&party, &acknowledged);
            discovery["agent_receipt"] = receipt.clone().unwrap_or(serde_json::Value::Null);
            let Ok(response) = self
                .http
                .post(format!("{}/v1/lobbies/poll", self.origin))
                .bearer_auth(token.unwrap())
                .json(&serde_json::json!({"seats":seats,"discovery":discovery}))
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
            *self.waiting.lock().unwrap() =
                serde_json::json!({"room_code":updates.room_code,"pending":updates.pending});
            // Apply confirmed profiles before lower-priority ticket requests.
            retire_unreported(&mut state.lock().unwrap(), &updates.updates);
            applied.retain(|account, _| updates.updates.iter().any(|u| &u.account == account));
            for u in &updates.updates {
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
                    // The cloud decides who holds a cloud seat: an account it
                    // moved elsewhere gives this one up and is applied again.
                    let moved: Vec<_> = local
                        .bindings
                        .iter()
                        .filter(|(bound, p)| {
                            **p == player && *bound != &id && bound.starts_with("cloud_")
                        })
                        .map(|(bound, _)| bound.clone())
                        .collect();
                    for bound in moved {
                        local.bindings.remove(&bound);
                        applied.remove(&bound["cloud_".len()..]);
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
                            username: u.profile.display_name.clone(),
                            skin_color: u.profile.skin_color.clone(),
                            preferred_color: u.profile.preferred_color.clone(),
                            avatar: u.profile.avatar.clone(),
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
                    applied.insert(u.account.clone(), (u.seat.clone(), u.profile_revision));
                }
            }
            // A phone that asked to play on its own gets a player first; the
            // cloud links it once a poll has reported that player's seat.
            for (id, player) in phone_seats.clone() {
                if !updates.pending.iter().any(|p| p["id"] == id.as_str()) {
                    phone_seats.remove(&id);
                    // Linked when the cloud reports an account on its seat.
                    let linked = player.is_some_and(|player| {
                        updates
                            .updates
                            .iter()
                            .any(|u| u.seat.player == player.0.to_string())
                    });
                    if let (Some(player), false) = (player, linked) {
                        crate::phones::remove(&state, player).await;
                    }
                }
            }
            for waiting in updates.pending.iter().filter(|p| p["phone_seat"] == true) {
                let Some(id) = waiting["id"].as_str() else {
                    continue;
                };
                match phone_seats.get(id).copied() {
                    None => {
                        let player = crate::phones::create(&state, &waiting["profile"])
                            .await
                            .ok();
                        phone_seats.insert(id.to_string(), player);
                        self.refresh.notify_one();
                    }
                    Some(Some(player))
                        if seats.iter().any(|s| s.player == player.0.to_string()) =>
                    {
                        let status = self.pickup(&state, id, player).await;
                        tracing::info!(%status, "linking a phone player");
                        if !status.is_success() && status != axum::http::StatusCode::GONE {
                            crate::phones::remove(&state, player).await;
                            phone_seats.insert(id.to_string(), None);
                        }
                    }
                    _ => {}
                }
            }
            // The cloud knows every seat now, so a main player whose pickup
            // came too early for a new controller is collected after all.
            crate::local_room::claim_main_for_first_seat(&state, &party).await;
            // Before applying a selection, so a newly granted game is already
            // eligible when the party picks it.
            if delivered_grants.as_ref() != Some(&updates.grants)
                && deliver_grants(&state, &updates.grants).await
            {
                delivered_grants = Some(updates.grants.clone());
            }
            let key = playtest_key(&updates.playtests);
            if !updates.playtests.is_empty()
                && delivered_playtests
                    .as_ref()
                    .is_none_or(|(known, at)| *known != key || at.elapsed() > PLAYTEST_RESEND)
                && deliver(
                    &state,
                    ClientMessage::Playtests {
                        playtests: updates.playtests.clone(),
                    },
                )
                .await
            {
                delivered_playtests = Some((key, std::time::Instant::now()));
            }
            if let Some(selection) = &updates.selection {
                if selection.command.is_some() {
                    if receipt.as_ref().and_then(|r| r["id"].as_str()) != Some(&selection.id) {
                        let result = if seats.contains(&selection.seat)
                            && updates.updates.iter().any(|u| u.seat == selection.seat)
                        {
                            settings::apply(&state, selection).await
                        } else {
                            Err("Player is no longer linked to this room".into())
                        };
                        receipt = Some(serde_json::json!({"id":selection.id,"ok":result.is_ok(),
                            "message":match result {Ok(())=>"Host accepted the settings. They take effect at the time specified by the game.".to_string(),Err(e)=>e}}));
                    }
                } else if acknowledged.as_ref() != Some(&selection.id)
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
                tokio::select! {
                    _ = self.pairing_url(&query) => {},
                    _ = self.refresh.notified() => {
                        // A slow ticket endpoint must not hold up a pickup.
                        // Keep the wake permit for the next full poll.
                        self.refresh.notify_one();
                        break;
                    },
                }
            }
        }
    }
}

/// The cloud is the authority on cloud links. Drop every local one it no
/// longer reports, not only those this process applied: a party carried over
/// an update or a room registered again keeps links the cloud never sent here.
/// Such a stale link held its seat, so each phone that chose that seat was
/// unlinked again a few seconds later. A seat another account takes over in
/// the same poll keeps its revision, so that account's link still applies.
fn retire_unreported(local: &mut crate::ServerState, updates: &[Update]) {
    let retired: Vec<_> = local
        .bindings
        .iter()
        .filter(|(id, _)| {
            id.strip_prefix("cloud_")
                .is_some_and(|account| !updates.iter().any(|u| u.account == account))
        })
        .map(|(id, player)| (id.clone(), *player))
        .collect();
    for (id, player) in retired {
        local.bindings.remove(&id);
        let revision = *local.link_revisions.get(&player).unwrap_or(&0);
        let taken_over = updates
            .iter()
            .any(|u| u.seat.player == player.0.to_string() && u.seat.revision == revision);
        if !taken_over {
            *local.link_revisions.entry(player).or_default() += 1;
        }
    }
}

/// Hand the daemon the current download grants. False when it could not be
/// reached, so the next poll tries again.
async fn deliver_grants(state: &SharedState, grants: &BTreeMap<String, String>) -> bool {
    deliver(
        state,
        ClientMessage::DownloadGrants {
            grants: grants.clone(),
        },
    )
    .await
}

/// Send the daemon one message. False when it could not be reached.
async fn deliver(state: &SharedState, message: ClientMessage) -> bool {
    let Ok((mut ws, _)) = daemon::connect(state).await else {
        return false;
    };
    let sent = ws
        .send(tokio_tungstenite::tungstenite::Message::Text(
            message.to_json(),
        ))
        .await
        .is_ok();
    let _ = ws.close(None).await;
    sent
}

#[cfg(test)]
mod grant_tests {
    use super::*;

    #[test]
    fn polls_without_grants_mean_none() {
        let updates: Updates = serde_json::from_str(r#"{"updates":[]}"#).unwrap();
        assert!(updates.grants.is_empty());
        let updates: Updates =
            serde_json::from_str(r#"{"updates":[],"grants":{"paid-game":"tok-1.a"}}"#).unwrap();
        assert_eq!(updates.grants["paid-game"], "tok-1.a");
        assert!(updates.playtests.is_empty());
        let updates: Updates = serde_json::from_str(
            r#"{"updates":[],"playtests":[{"entry":{"id":"hexstead"},"versions":{"windows":"0.3.1"},"grant":"9.a"}]}"#,
        )
        .unwrap();
        assert_eq!(playtest_key(&updates.playtests)[0].1["windows"], "0.3.1");
    }
}

#[cfg(test)]
mod pickup_tests {
    use super::*;
    use axum::{routing::post, Router};
    use tokio::net::TcpListener;

    async fn pickup_fixture(stale: bool) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap().to_string();
        let host = tokio::spawn(gamenight_daemon::run_with_library(listener, Vec::new()));
        let state = Arc::new(Mutex::new(crate::ServerState::new(addr)));
        let (mut ws, _) = daemon::connect(&state).await.unwrap();
        for name in ["Guest", "Other"] {
            ws.send(tokio_tungstenite::tungstenite::Message::Text(
                ClientMessage::JoinParty {
                    name: name.into(),
                    seat: None,
                    color: None,
                    avatar: None,
                    library: vec![],
                }
                .to_json(),
            ))
            .await
            .unwrap();
        }
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let bridge = Bridge {
            origin: format!("http://{}", listener.local_addr().unwrap()),
            http: reqwest::Client::new(),
            session: Arc::new(Mutex::new(Some("fixture".into()))),
            seats: Arc::default(),
            waiting: Arc::default(),
            pairing: Arc::default(),
            pairing_request: Arc::default(),
            refresh: Arc::default(),
        };
        state.lock().unwrap().cloud = Some(bridge.clone());
        let seats = tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                let (seats, _) = bridge.snapshot(&state).await.unwrap();
                if seats.len() == 2 {
                    break seats;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        let player = PlayerId(uuid::Uuid::parse_str(&seats[0].player).unwrap());
        let claimed: Arc<Mutex<Option<serde_json::Value>>> = Arc::default();
        let ticket_started = Arc::new(tokio::sync::Notify::new());
        let confirmed = Arc::new(tokio::sync::Notify::new());
        let app = Router::new()
            .route("/v1/lobbies/pickup", post({
                let claimed = claimed.clone(); let state = state.clone();
                move |Json(body): Json<serde_json::Value>| {
                    let claimed = claimed.clone(); let state = state.clone();
                    async move {
                        if body["pending"] == "rejected" { return axum::http::StatusCode::GONE; }
                        *claimed.lock().unwrap() = Some(body["seat"].clone());
                        if stale { *state.lock().unwrap().link_revisions.entry(player).or_default() += 1; }
                        axum::http::StatusCode::NO_CONTENT
                    }
                }
            }))
            .route("/v1/lobbies/poll", post({
                let claimed = claimed.clone(); let confirmed = confirmed.clone();
                move |Json(body): Json<serde_json::Value>| {
                    let claimed = claimed.clone(); let confirmed = confirmed.clone();
                    async move {
                        assert_eq!(body["seats"].as_array().unwrap().len(), 2);
                        assert!(body["discovery"].is_object(), "pickup must preserve discovery");
                        let updates = claimed.lock().unwrap().as_ref().map(|seat| {
                            confirmed.notify_one();
                            vec![serde_json::json!({"seat":seat,"account":"fixture-account","profile_revision":7,
                                "profile":{"display_name":"Ada","skin_color":"#ff0000","avatar":"fixture-face"}})]
                        }).unwrap_or_default();
                        Json(serde_json::json!({"updates":updates,"room_code":"ABCDEF"}))
                    }
                }
            }))
            .route("/v1/lobbies/ticket", post({
                let started = ticket_started.clone();
                move || { let started = started.clone(); async move {
                    started.notify_one();
                    std::future::pending::<()>().await;
                    Json(serde_json::json!({"ticket":"unused"}))
                }}
            }));
        let cloud = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        // Rejected claims cannot trigger a profile refresh.
        assert_eq!(
            bridge.pickup(&state, "rejected", player).await,
            axum::http::StatusCode::GONE
        );
        assert!(
            tokio::time::timeout(Duration::from_millis(50), bridge.refresh.notified())
                .await
                .is_err()
        );
        let runner = tokio::spawn(bridge.clone().run(state.clone()));
        bridge.refresh.notify_one();
        tokio::time::timeout(Duration::from_secs(2), ticket_started.notified())
            .await
            .unwrap();
        assert_eq!(
            bridge.pickup(&state, "accepted", player).await,
            axum::http::StatusCode::NO_CONTENT
        );
        // Both the 3s heartbeat and an indefinitely blocked ticket must be bypassed.
        tokio::time::timeout(Duration::from_secs(2), confirmed.notified())
            .await
            .unwrap();
        if stale {
            tokio::time::timeout(Duration::from_secs(2), ticket_started.notified())
                .await
                .unwrap();
            let (_, party) = bridge.snapshot(&state).await.unwrap();
            assert_ne!(
                party.players.iter().find(|p| p.id == player).unwrap().name,
                "Ada"
            );
            assert!(state.lock().unwrap().bindings.is_empty());
        } else {
            tokio::time::timeout(Duration::from_secs(2), async {
                loop {
                    let (_, party) = bridge.snapshot(&state).await.unwrap();
                    let p = party.players.iter().find(|p| p.id == player).unwrap();
                    // Name and avatar arrive as separate daemon commands. Wait
                    // for the complete profile within the same latency bound.
                    if p.name == "Ada" && p.avatar.as_deref() == Some("fixture-face") {
                        assert_eq!(party.players.len(), 2);
                        break;
                    }
                    tokio::task::yield_now().await;
                }
            })
            .await
            .unwrap();
        }
        runner.abort();
        cloud.abort();
        host.abort();
        let _ = ws.close(None).await;
    }

    #[tokio::test]
    async fn successful_pickup_interrupts_ticket_and_applies_profile_without_heartbeat_delay() {
        pickup_fixture(false).await;
    }
    #[tokio::test]
    async fn immediate_pickup_refresh_still_rejects_an_unlinked_seat() {
        pickup_fixture(true).await;
    }
}

#[cfg(test)]
mod retire_tests {
    use super::*;

    fn update(account: &str, player: PlayerId, revision: u64) -> Update {
        serde_json::from_value(serde_json::json!({
            "seat":{"index":0,"player":player.0.to_string(),"revision":revision},
            "account":account,"profile_revision":1,
            "profile":{"display_name":"Joep","skin_color":"#abcdef","avatar":""}
        }))
        .unwrap()
    }

    #[test]
    fn a_stale_cloud_link_gives_its_seat_to_the_phone_that_chose_it() {
        let mut local = crate::ServerState::new("127.0.0.1:1".into());
        let seat = PlayerId(uuid::Uuid::new_v4());
        let other = PlayerId(uuid::Uuid::new_v4());
        let lan = PlayerId(uuid::Uuid::new_v4());
        // Carried from before an update or a new room: the cloud never sent it.
        local.bindings.insert("cloud_old".into(), seat);
        local.bindings.insert("cloud_gone".into(), other);
        local.bindings.insert("lan-profile".into(), lan);
        local.link_revisions.insert(seat, 3);
        retire_unreported(&mut local, &[update("guest:phone", seat, 3)]);
        assert_eq!(local.bindings.len(), 1, "only the LAN link stays");
        assert!(local.bindings.contains_key("lan-profile"));
        // The phone's claim still matches the seat, so it applies.
        assert_eq!(local.link_revisions[&seat], 3);
        // A seat nobody takes over is revoked like before.
        assert_eq!(local.link_revisions[&other], 1);
    }
}
