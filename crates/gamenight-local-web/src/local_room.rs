use crate::{join_session, JoinSessionRequest, Profile, SharedState};
use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};
use gamenight_protocol::PlayerId;
use serde::Deserialize;
use std::{
    collections::HashMap,
    time::{Instant, SystemTime, UNIX_EPOCH},
};
fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
pub struct Room {
    code: String,
    pending: HashMap<String, (String, u64)>,
    /// When each code-joined profile arrived at the doors, as a running count.
    arrivals: HashMap<String, u64>,
    next_arrival: u64,
    attempts: (Instant, u32),
    pub main_profile: Option<String>,
}
impl Room {
    pub fn new() -> Self {
        let random = uuid::Uuid::new_v4();
        let alphabet = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
        Self {
            code: random.as_bytes()[..6]
                .iter()
                .map(|b| alphabet[*b as usize % alphabet.len()] as char)
                .collect(),
            pending: HashMap::new(),
            arrivals: HashMap::new(),
            next_arrival: 0,
            attempts: (Instant::now(), 0),
            main_profile: None,
        }
    }
    pub fn code(&self) -> &str {
        &self.code
    }
    pub fn set_code(&mut self, code: String) {
        self.code = code;
    }
    pub fn restore(&mut self, profile: &str) {
        self.arrivals.remove(profile);
        self.pending.insert(
            profile.into(),
            (uuid::Uuid::new_v4().to_string(), now() + 86400),
        );
    }
    pub fn waiting(&self, profile: &str) -> bool {
        self.pending
            .get(profile)
            .is_some_and(|(_, expires)| *expires > now())
    }
    fn arrival(&self, profile: &str) -> u64 {
        self.arrivals.get(profile).copied().unwrap_or(u64::MAX)
    }
    pub fn snapshot(&self, profiles: &HashMap<String, Profile>) -> serde_json::Value {
        let mut entries: Vec<_> = self.pending.iter().collect();
        // Arrival order. A restored main profile never arrived through a code,
        // so it sorts last and always keeps a door.
        entries.sort_by_key(|(profile, _)| (self.arrival(profile), *profile));
        let pending:Vec<_>=entries.into_iter().filter_map(|(profile,(id,expires))| {
            let p=profiles.get(profile)?;
            (*expires>now()).then(||serde_json::json!({"id":id,"expires":expires,"profile":{"display_name":p.username,"skin_color":p.skin_color,"preferred_color":p.preferred_color,"avatar":p.avatar}}))
        }).collect();
        serde_json::json!({"room_code":self.code,"pending":pending})
    }
}
/// Profiles that can wait at the doors at once.
const MAX_PENDING: usize = 4;
#[derive(Deserialize)]
pub struct Join {
    code: String,
    profile: String,
    #[serde(default)]
    remember: Option<bool>,
}
pub async fn join(State(state): State<SharedState>, Json(req): Json<Join>) -> StatusCode {
    let mut s = state.lock().unwrap();
    if s.cloud.is_some() {
        return StatusCode::NOT_FOUND;
    }
    if s.local_room.attempts.0.elapsed().as_secs() >= 60 {
        s.local_room.attempts = (Instant::now(), 0);
    }
    s.local_room.attempts.1 += 1;
    if s.local_room.attempts.1 > 20 {
        return StatusCode::TOO_MANY_REQUESTS;
    }
    if req.code.trim().to_uppercase() != s.local_room.code {
        return StatusCode::NOT_FOUND;
    }
    if !s.profiles.contains_key(&req.profile) {
        return StatusCode::NOT_FOUND;
    }
    if s.bindings.contains_key(&req.profile) {
        return StatusCode::CONFLICT;
    }
    s.local_room
        .pending
        .retain(|_, (_, expires)| *expires > now());
    // First in, first out: a full door row makes room for the newcomer by
    // sending the longest-waiting profile away.
    if s.local_room.pending.len() >= MAX_PENDING && !s.local_room.pending.contains_key(&req.profile)
    {
        let room = &s.local_room;
        let oldest = room
            .pending
            .keys()
            .min_by_key(|profile| room.arrival(profile))
            .cloned();
        if let Some(oldest) = oldest {
            s.local_room.pending.remove(&oldest);
        }
    }
    let profile = s.profiles[&req.profile].clone();
    if s.memory.linked(&profile, req.remember).is_err() {
        return StatusCode::INTERNAL_SERVER_ERROR;
    }
    s.local_room.main_profile = s.memory.main_profile.clone();
    if !s.local_room.pending.contains_key(&req.profile) {
        let arrival = s.local_room.next_arrival;
        s.local_room.next_arrival += 1;
        s.local_room.arrivals.insert(req.profile.clone(), arrival);
    }
    s.local_room
        .pending
        .entry(req.profile)
        .or_insert_with(|| (uuid::Uuid::new_v4().to_string(), now() + 300));
    StatusCode::NO_CONTENT
}
#[derive(Deserialize)]
pub struct PhoneSeat {
    profile: String,
}
/// A waiting phone takes a seat of its own and plays on the phone, for when
/// there are more phones than controllers.
pub async fn phone_seat(
    State(state): State<SharedState>,
    Json(req): Json<PhoneSeat>,
) -> StatusCode {
    let (pending, profile) = {
        let s = state.lock().unwrap();
        if s.cloud.is_some() {
            return StatusCode::NOT_FOUND;
        }
        let Some((id, _)) = s
            .local_room
            .pending
            .get(&req.profile)
            .filter(|(_, expires)| *expires > now())
        else {
            return StatusCode::GONE;
        };
        let Some(p) = s.profiles.get(&req.profile) else {
            return StatusCode::NOT_FOUND;
        };
        (
            id.clone(),
            serde_json::json!({"display_name":p.username,"preferred_color":p.preferred_color,"avatar":p.avatar}),
        )
    };
    crate::phones::seat_waiting(&state, &pending, &profile).await
}
pub async fn cancel(Path(id): Path<String>, State(state): State<SharedState>) -> StatusCode {
    state.lock().unwrap().local_room.pending.remove(&id);
    StatusCode::NO_CONTENT
}
pub async fn pickup(state: &SharedState, pending: &str, player: PlayerId) -> StatusCode {
    let (profile, revision, entry) = {
        let mut s = state.lock().unwrap();
        if s.bindings.values().any(|p| *p == player) {
            return StatusCode::CONFLICT;
        }
        let Some(profile) = s
            .local_room
            .pending
            .iter()
            .find(|(_, (id, expires))| id == pending && *expires > now())
            .map(|(p, _)| p.clone())
        else {
            return StatusCode::GONE;
        };
        let entry = s.local_room.pending.remove(&profile).unwrap();
        let revision = s.link_revisions.get(&player).copied().unwrap_or(0);
        (profile, revision, entry)
    };
    let result = join_session(
        Path(profile.clone()),
        State(state.clone()),
        Json(JoinSessionRequest {
            claim: Some(player),
            seat: None,
            link_revision: revision,
        }),
    )
    .await;
    match result {
        Ok(Json(v)) if v["status"] == "claimed" || v["status"] == "joined" => {
            StatusCode::NO_CONTENT
        }
        other => {
            state
                .lock()
                .unwrap()
                .local_room
                .pending
                .insert(profile, entry);
            other.err().unwrap_or(StatusCode::CONFLICT)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn code_join_waits_for_native_pickup_and_can_be_cancelled() {
        let state = std::sync::Arc::new(std::sync::Mutex::new(crate::ServerState::new(
            "127.0.0.1:1".into(),
        )));
        state.lock().unwrap().profiles.insert(
            "phone".into(),
            Profile {
                id: "phone".into(),
                username: "Test".into(),
                skin_color: "#abcdef".into(),
                preferred_color: None,
                avatar: "drawing".into(),
            },
        );
        let code = state.lock().unwrap().local_room.code.clone();
        assert_eq!(code.len(), 6);
        assert_eq!(
            join(
                State(state.clone()),
                Json(Join {
                    code: "wrong".into(),
                    remember: None,
                    profile: "phone".into()
                })
            )
            .await,
            StatusCode::NOT_FOUND
        );
        assert_eq!(
            join(
                State(state.clone()),
                Json(Join {
                    code,
                    remember: None,
                    profile: "phone".into()
                })
            )
            .await,
            StatusCode::NO_CONTENT
        );
        {
            let s = state.lock().unwrap();
            assert!(s.bindings.is_empty());
            assert!(s.local_room.waiting("phone"));
            assert_eq!(
                s.local_room.snapshot(&s.profiles)["pending"][0]["profile"]["skin_color"],
                "#abcdef"
            );
        }
        cancel(Path("phone".into()), State(state.clone())).await;
        assert!(!state.lock().unwrap().local_room.waiting("phone"));
        // A full row of doors: the newest arrival sends the oldest away.
        for i in 0..=MAX_PENDING {
            let id = format!("guest{i}");
            state.lock().unwrap().profiles.insert(
                id.clone(),
                Profile {
                    id: id.clone(),
                    username: id.clone(),
                    skin_color: "#abcdef".into(),
                    preferred_color: None,
                    avatar: String::new(),
                },
            );
            let code = state.lock().unwrap().local_room.code.clone();
            let joined = join(
                State(state.clone()),
                Json(Join {
                    code,
                    remember: None,
                    profile: id,
                }),
            )
            .await;
            assert_eq!(joined, StatusCode::NO_CONTENT);
        }
        {
            let s = state.lock().unwrap();
            assert!(!s.local_room.waiting("guest0"));
            let names: Vec<_> = s.local_room.snapshot(&s.profiles)["pending"]
                .as_array()
                .unwrap()
                .iter()
                .map(|p| p["profile"]["display_name"].as_str().unwrap().to_string())
                .collect();
            assert_eq!(names, ["guest1", "guest2", "guest3", "guest4"]);
        }
        state.lock().unwrap().local_room.pending.clear();
        for _ in 0..20 {
            let _ = join(
                State(state.clone()),
                Json(Join {
                    code: "wrong".into(),
                    remember: None,
                    profile: "phone".into(),
                }),
            )
            .await;
        }
        assert_eq!(
            join(
                State(state),
                Json(Join {
                    code: "wrong".into(),
                    remember: None,
                    profile: "phone".into()
                })
            )
            .await,
            StatusCode::TOO_MANY_REQUESTS
        );
    }
}

#[derive(Deserialize)]
pub struct Remember {
    remember: bool,
}
pub async fn remember(
    Path(id): Path<String>,
    State(state): State<SharedState>,
    Json(req): Json<Remember>,
) -> StatusCode {
    let mut s = state.lock().unwrap();
    if s.cloud.is_some() {
        return StatusCode::NOT_FOUND;
    }
    if !s.bindings.contains_key(&id) && !s.local_room.waiting(&id) {
        return StatusCode::FORBIDDEN;
    }
    let Some(profile) = s.profiles.get(&id).cloned() else {
        return StatusCode::NOT_FOUND;
    };
    match s.memory.set(&profile, req.remember) {
        Ok(()) => {
            s.local_room.main_profile = s.memory.main_profile.clone();
            StatusCode::NO_CONTENT
        }
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR,
    }
}

#[derive(Deserialize)]
pub struct MainPlayer {
    enabled: bool,
}
pub async fn main_player(
    Path(id): Path<String>,
    State(state): State<SharedState>,
    Json(req): Json<MainPlayer>,
) -> StatusCode {
    let mut s = state.lock().unwrap();
    if s.cloud.is_some() {
        return StatusCode::NOT_FOUND;
    }
    if !s.bindings.contains_key(&id) && !s.local_room.waiting(&id) {
        return StatusCode::FORBIDDEN;
    }
    let Some(profile) = s.profiles.get(&id).cloned() else {
        return StatusCode::NOT_FOUND;
    };
    match s.memory.main_player(&profile, req.enabled) {
        Ok(()) => {
            s.local_room.main_profile = s.memory.main_profile.clone();
            StatusCode::NO_CONTENT
        }
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR,
    }
}

#[cfg(test)]
mod memory_access_tests {
    use super::*;
    #[tokio::test]
    async fn only_waiting_or_linked_profiles_can_change_memory_without_leaving() {
        let state = std::sync::Arc::new(std::sync::Mutex::new(crate::ServerState::new(
            "127.0.0.1:1".into(),
        )));
        state.lock().unwrap().profiles.insert(
            "phone".into(),
            Profile {
                id: "phone".into(),
                username: "Joep".into(),
                skin_color: "#abcdef".into(),
                preferred_color: None,
                avatar: "hat".into(),
            },
        );
        assert_eq!(
            remember(
                Path("phone".into()),
                State(state.clone()),
                Json(Remember { remember: true })
            )
            .await,
            StatusCode::FORBIDDEN
        );
        assert_eq!(
            main_player(
                Path("phone".into()),
                State(state.clone()),
                Json(MainPlayer { enabled: true })
            )
            .await,
            StatusCode::FORBIDDEN
        );
        state.lock().unwrap().local_room.restore("phone");
        assert_eq!(
            main_player(
                Path("phone".into()),
                State(state.clone()),
                Json(MainPlayer { enabled: true })
            )
            .await,
            StatusCode::NO_CONTENT
        );
        assert_eq!(
            state.lock().unwrap().memory.main_profile.as_deref(),
            Some("phone")
        );
        assert_eq!(
            remember(
                Path("phone".into()),
                State(state.clone()),
                Json(Remember { remember: true })
            )
            .await,
            StatusCode::NO_CONTENT
        );
        assert!(state.lock().unwrap().memory.profiles.contains_key("phone"));
        let player = PlayerId(uuid::Uuid::new_v4());
        state
            .lock()
            .unwrap()
            .bindings
            .insert("phone".into(), player);
        state.lock().unwrap().local_room.pending.clear();
        assert_eq!(
            remember(
                Path("phone".into()),
                State(state.clone()),
                Json(Remember { remember: false })
            )
            .await,
            StatusCode::NO_CONTENT
        );
        let s = state.lock().unwrap();
        assert!(!s.memory.profiles.contains_key("phone"));
        assert!(s.memory.main_profile.is_none());
        assert_eq!(s.bindings["phone"], player);
    }
}
