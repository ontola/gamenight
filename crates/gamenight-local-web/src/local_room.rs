use crate::{join_session, JoinSessionRequest, Profile, SharedState};
use axum::{extract::{Path, State}, http::StatusCode, Json};
use gamenight_protocol::PlayerId;
use serde::Deserialize;
use std::{collections::HashMap, time::{Instant, SystemTime, UNIX_EPOCH}};
fn now() -> u64 { SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() }
pub struct Room {
    code: String,
    pending: HashMap<String,(String,u64)>,
    attempts: (Instant,u32),
}
impl Room {
    pub fn new() -> Self {
        let random=uuid::Uuid::new_v4();
        let alphabet=b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
        Self { code:random.as_bytes()[..6].iter().map(|b|alphabet[*b as usize % alphabet.len()] as char).collect(),pending:HashMap::new(),attempts:(Instant::now(),0) }
    }
    pub fn waiting(&self, profile:&str)->bool { self.pending.get(profile).is_some_and(|(_,expires)|*expires>now()) }
    pub fn snapshot(&self, profiles:&HashMap<String,Profile>)->serde_json::Value {
        let pending:Vec<_>=self.pending.iter().filter_map(|(profile,(id,expires))| {
            let p=profiles.get(profile)?;
            (*expires>now()).then(||serde_json::json!({"id":id,"expires":expires,"profile":{"display_name":p.username,"skin_color":p.skin_color,"avatar":p.avatar}}))
        }).collect();
        serde_json::json!({"room_code":self.code,"pending":pending})
    }
}
#[derive(Deserialize)]
pub struct Join { code:String, profile:String }
pub async fn join(State(state):State<SharedState>,Json(req):Json<Join>)->StatusCode {
    let mut s=state.lock().unwrap();
    if s.cloud.is_some(){return StatusCode::NOT_FOUND;}
    if s.local_room.attempts.0.elapsed().as_secs()>=60 {s.local_room.attempts=(Instant::now(),0);}
    s.local_room.attempts.1+=1;
    if s.local_room.attempts.1>20{return StatusCode::TOO_MANY_REQUESTS;}
    if req.code.trim().to_uppercase()!=s.local_room.code{return StatusCode::NOT_FOUND;}
    if !s.profiles.contains_key(&req.profile){return StatusCode::NOT_FOUND;}
    if s.bindings.contains_key(&req.profile){return StatusCode::CONFLICT;}
    s.local_room.pending.retain(|_,(_,expires)|*expires>now());
    if s.local_room.pending.len()>=4 && !s.local_room.pending.contains_key(&req.profile){return StatusCode::TOO_MANY_REQUESTS;}
    s.local_room.pending.entry(req.profile).or_insert_with(||(uuid::Uuid::new_v4().to_string(),now()+300));
    StatusCode::NO_CONTENT
}
pub async fn cancel(Path(id):Path<String>,State(state):State<SharedState>)->StatusCode {
    state.lock().unwrap().local_room.pending.remove(&id);
    StatusCode::NO_CONTENT
}
pub async fn pickup(state:&SharedState,pending:&str,player:PlayerId)->StatusCode {
    let (profile,revision,entry)={
        let mut s=state.lock().unwrap();
        if s.bindings.values().any(|p|*p==player){return StatusCode::CONFLICT;}
        let Some(profile)=s.local_room.pending.iter().find(|(_, (id,expires))|id==pending && *expires>now()).map(|(p,_)|p.clone()) else{return StatusCode::GONE;};
        let entry=s.local_room.pending.remove(&profile).unwrap();
        let revision=s.link_revisions.get(&player).copied().unwrap_or(0);
        (profile,revision,entry)
    };
    let result=join_session(Path(profile.clone()),State(state.clone()),Json(JoinSessionRequest{claim:Some(player),seat:None,link_revision:revision})).await;
    match result {
        Ok(Json(v)) if v["status"]=="claimed" || v["status"]=="joined" => StatusCode::NO_CONTENT,
        other=>{state.lock().unwrap().local_room.pending.insert(profile,entry);other.err().unwrap_or(StatusCode::CONFLICT)}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn code_join_waits_for_native_pickup_and_can_be_cancelled() {
        let state=std::sync::Arc::new(std::sync::Mutex::new(crate::ServerState::new("127.0.0.1:1".into())));
        state.lock().unwrap().profiles.insert("phone".into(),Profile{id:"phone".into(),username:"Test".into(),skin_color:"#abcdef".into(),avatar:"drawing".into()});
        let code=state.lock().unwrap().local_room.code.clone();
        assert_eq!(code.len(),6);
        assert_eq!(join(State(state.clone()),Json(Join{code:"wrong".into(),profile:"phone".into()})).await,StatusCode::NOT_FOUND);
        assert_eq!(join(State(state.clone()),Json(Join{code,profile:"phone".into()})).await,StatusCode::NO_CONTENT);
        {let s=state.lock().unwrap();assert!(s.bindings.is_empty());assert!(s.local_room.waiting("phone"));assert_eq!(s.local_room.snapshot(&s.profiles)["pending"][0]["profile"]["skin_color"],"#abcdef");}
        cancel(Path("phone".into()),State(state.clone())).await;
        assert!(!state.lock().unwrap().local_room.waiting("phone"));
        for _ in 0..20 { let _=join(State(state.clone()),Json(Join{code:"wrong".into(),profile:"phone".into()})).await; }
        assert_eq!(join(State(state),Json(Join{code:"wrong".into(),profile:"phone".into()})).await,StatusCode::TOO_MANY_REQUESTS);
    }
}
