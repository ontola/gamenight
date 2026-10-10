//! What a linked phone may do to the room over the LAN: see which games this
//! host can play, add one to the end of the queue, play or start one next,
//! and change the match settings of the current or next game.
//!
//! A phone proves who it is with its profile id, which this server bound to a
//! party member when the phone signed in (like `/api/profiles/:id/*` and the
//! phone screens). It never names a player itself, so it can only act as the
//! character it is driving.
use crate::{
    cloud::{discovery, settings, Seat},
    daemon, playlist, SharedState,
};
use axum::{
    extract::{Query, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use futures_util::{SinkExt, StreamExt};
use gamenight_protocol::{ClientMessage, GameId, PartySnapshot, ServerMessage};
use serde::Deserialize;
use serde_json::{json, Value};
use tokio_tungstenite::tungstenite::Message;

/// The seat the player bound to `profile` sits in, if they are still seated.
pub(crate) fn seat(state: &SharedState, party: &PartySnapshot, profile: &str) -> Option<Seat> {
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

#[derive(Deserialize)]
pub struct ProfileQuery {
    profile: String,
    /// For settings: this game instead of the one on screen, when it is
    /// being played or warmed up.
    #[serde(default)]
    game: Option<String>,
}

/// `GET /api/games?profile=…`: the games on this host and whether the party
/// can play each one now. Only `selectable` games can be queued.
pub(crate) async fn games(
    State(state): State<SharedState>,
    Query(query): Query<ProfileQuery>,
) -> Result<Json<Value>, StatusCode> {
    let party = daemon::party(&state).await?;
    seat(&state, &party, &query.profile).ok_or(StatusCode::FORBIDDEN)?;
    let title = |id: &str| {
        party
            .library
            .iter()
            .find(|g| g.id.0 == id)
            .map(|g| g.title.clone())
            .or_else(|| {
                party
                    .installs
                    .iter()
                    .find(|i| i.game.0 == id)
                    .map(|i| i.title.clone())
            })
    };
    let mut view = discovery::snapshot(&party, &None);
    let games: Vec<Value> = view["games"]
        .as_array_mut()
        .map(std::mem::take)
        .unwrap_or_default()
        .into_iter()
        .map(|g| {
            let id = g["id"].as_str().unwrap_or_default();
            json!({"id": id, "title": title(id), "selectable": g["selectable"], "state": g["state"]})
        })
        .collect();
    Ok(Json(json!({ "games": games })))
}

#[derive(Deserialize)]
pub struct QueueRequest {
    profile: String,
    game: String,
}

/// `POST /api/playlist/queue`: adds a game this host can play to the end of
/// the queue. Never starts or interrupts play. Answers with the playlist,
/// like `/api/playlist`.
pub(crate) async fn queue(
    State(state): State<SharedState>,
    Json(request): Json<QueueRequest>,
) -> Result<Json<playlist::View>, StatusCode> {
    let (mut ws, party) = daemon::connect(&state).await?;
    seat(&state, &party, &request.profile).ok_or(StatusCode::FORBIDDEN)?;
    let playable = discovery::snapshot(&party, &None)["games"]
        .as_array()
        .is_some_and(|games| {
            games
                .iter()
                .any(|g| g["id"] == request.game.as_str() && g["selectable"] == true)
        });
    if !playable {
        return Err(StatusCode::CONFLICT);
    }
    let game = GameId(request.game);
    let count = |party: &PartySnapshot| {
        party
            .playlist
            .entries
            .iter()
            .filter(|e| e.game == game)
            .count()
    };
    let before = count(&party);
    ws.send(Message::Text(
        ClientMessage::QueueGame {
            game: game.clone(),
            first: false,
        }
        .to_json(),
    ))
    .await
    .map_err(|_| StatusCode::BAD_GATEWAY)?;
    tokio::time::timeout(daemon::REPLY_TIMEOUT * 2, async {
        while let Some(message) = ws.next().await {
            let Message::Text(text) = message.map_err(|_| StatusCode::BAD_GATEWAY)? else {
                continue;
            };
            match serde_json::from_str::<ServerMessage>(&text) {
                Ok(ServerMessage::PartyState { party }) if count(&party) > before => {
                    let _ = ws.close(None).await;
                    return Ok(Json(party.into()));
                }
                Ok(ServerMessage::Error { .. }) => return Err(StatusCode::CONFLICT),
                _ => {}
            }
        }
        Err(StatusCode::BAD_GATEWAY)
    })
    .await
    .map_err(|_| StatusCode::GATEWAY_TIMEOUT)?
}

#[derive(Deserialize)]
pub struct NextRequest {
    profile: String,
    game: String,
    /// Start it right away; otherwise it only becomes the next game.
    #[serde(default)]
    start: bool,
}

/// `POST /api/playlist/next`: makes a game this host can play the next one
/// up (it starts loading), or with `start` plays it now: the current game
/// ends as soon as it has loaded. Answers with the playlist.
pub(crate) async fn next(
    State(state): State<SharedState>,
    Json(request): Json<NextRequest>,
) -> Result<Json<playlist::View>, StatusCode> {
    let party = daemon::party(&state).await?;
    let seat = seat(&state, &party, &request.profile).ok_or(StatusCode::FORBIDDEN)?;
    let selection = discovery::Selection {
        command: None,
        edit: None,
        id: uuid::Uuid::new_v4().to_string(),
        game: request.game,
        seat,
        expires: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs()
            + 30,
        start: request.start,
    };
    if !discovery::apply(&state, &selection).await {
        return Err(StatusCode::CONFLICT);
    }
    playlist::get(State(state)).await
}

/// `GET /api/settings?profile=…[&game=…]`: the match settings of the game
/// being played or warmed up (or of `game`, when it is either), or `null`
/// when it declared none.
pub(crate) async fn get_settings(
    State(state): State<SharedState>,
    Query(query): Query<ProfileQuery>,
) -> Result<Json<Option<Value>>, StatusCode> {
    let party = daemon::party(&state).await?;
    seat(&state, &party, &query.profile).ok_or(StatusCode::FORBIDDEN)?;
    Ok(Json(settings::controls_for(&party, query.game.as_deref())))
}

#[derive(Deserialize)]
pub struct SettingsRequest {
    profile: String,
    command: settings::Command,
}

/// `POST /api/settings`: changes, undoes or keeps settings as the profile's
/// player. A refusal (a stale revision, a value out of range) is a 409 whose
/// `error` says why.
pub(crate) async fn set_settings(
    State(state): State<SharedState>,
    Json(request): Json<SettingsRequest>,
) -> Response {
    let party = match daemon::party(&state).await {
        Ok(party) => party,
        Err(status) => return status.into_response(),
    };
    let Some(seat) = seat(&state, &party, &request.profile) else {
        return StatusCode::FORBIDDEN.into_response();
    };
    match settings::control(&state, &seat, None, &request.command).await {
        Ok(()) => Json(settings::controls(
            &daemon::party(&state).await.unwrap_or(party),
        ))
        .into_response(),
        Err(message) => (StatusCode::CONFLICT, Json(json!({ "error": message }))).into_response(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ServerState;
    use gamenight_protocol::{PlayerId, Role};
    use std::sync::{Arc, Mutex};

    async fn overlay(addr: &str) -> daemon::DaemonWs {
        let (mut ws, _) = tokio_tungstenite::connect_async(format!("ws://{addr}"))
            .await
            .unwrap();
        ws.send(Message::Text(
            ClientMessage::Hello {
                role: Role::Overlay,
                game: None,
                token: None,
            }
            .to_json(),
        ))
        .await
        .unwrap();
        daemon::read_welcome(&mut ws).await.unwrap();
        ws
    }

    /// A daemon with a connected game "test" that declared settings, an
    /// unplayable "elsewhere", and one seated player bound to profile "phone".
    async fn room() -> (SharedState, PlayerId, Vec<tokio::task::JoinHandle<()>>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap().to_string();
        let server = tokio::spawn(async move {
            let _ = gamenight_daemon::run_with_library(
                listener,
                vec![
                    serde_json::from_value(json!({"id":"test","title":"Test"})).unwrap(),
                    serde_json::from_value(json!({"id":"elsewhere","title":"Elsewhere"})).unwrap(),
                ],
            )
            .await;
        });
        let state = Arc::new(Mutex::new(ServerState::new(addr.clone())));
        let (mut game, _) = tokio_tungstenite::connect_async(format!("ws://{addr}"))
            .await
            .unwrap();
        game.send(Message::Text(
            json!({"type":"hello","role":"game","game":"test"}).to_string(),
        ))
        .await
        .unwrap();
        daemon::read_welcome(&mut game).await.unwrap();
        game.send(Message::Text(
            json!({"type":"declare_settings","settings":[
                {"key":"items","label":"Items","kind":"toggle","default":true},
                {"key":"stock","label":"Stock","kind":"number","default":3,"min":1,"max":9}
            ]})
            .to_string(),
        ))
        .await
        .unwrap();
        let mut seated = overlay(&addr).await;
        seated
            .send(Message::Text(
                json!({"type":"join_party","name":"Phone","seat":0}).to_string(),
            ))
            .await
            .unwrap();
        let player = daemon::wait_for_new_player(&mut seated, &Default::default())
            .await
            .unwrap();
        state
            .lock()
            .unwrap()
            .bindings
            .insert("phone".into(), player);
        // Keep the game and the seated overlay connected for the test.
        let keep = tokio::spawn(async move {
            let _game = game;
            let _seated = seated;
            std::future::pending::<()>().await;
        });
        (state, player, vec![server, keep])
    }

    fn profile(id: &str) -> Query<ProfileQuery> {
        Query(ProfileQuery {
            profile: id.into(),
            game: None,
        })
    }

    #[tokio::test]
    async fn linked_phone_sees_playable_games_and_appends_to_the_queue() {
        let (state, _, tasks) = room().await;
        assert_eq!(
            games(State(state.clone()), profile("stranger"))
                .await
                .unwrap_err(),
            StatusCode::FORBIDDEN
        );
        let Json(view) = games(State(state.clone()), profile("phone")).await.unwrap();
        let find = |id: &str| {
            view["games"]
                .as_array()
                .unwrap()
                .iter()
                .find(|g| g["id"] == id)
                .unwrap()
                .clone()
        };
        assert_eq!(find("test")["selectable"], true);
        assert_eq!(find("test")["title"], "Test");
        assert_eq!(find("elsewhere")["selectable"], false);
        assert!(!view.to_string().contains("launch"));

        let add = |profile: &str, game: &str| {
            queue(
                State(state.clone()),
                Json(QueueRequest {
                    profile: profile.into(),
                    game: game.into(),
                }),
            )
        };
        let before = daemon::party(&state).await.unwrap().playlist.entries.len();
        let Json(after) = add("phone", "test").await.unwrap();
        let after = serde_json::to_value(after).unwrap();
        let entries = after["playlist"]["entries"].as_array().unwrap();
        assert_eq!(entries.len(), before + 1);
        assert_eq!(entries.last().unwrap()["game"], "test");
        assert_eq!(
            add("phone", "elsewhere").await.unwrap_err(),
            StatusCode::CONFLICT
        );
        assert_eq!(
            add("phone", "not-on-host").await.unwrap_err(),
            StatusCode::CONFLICT
        );
        assert_eq!(
            add("stranger", "test").await.unwrap_err(),
            StatusCode::FORBIDDEN
        );
        tasks.iter().for_each(|t| t.abort());
    }

    #[tokio::test]
    async fn linked_phone_plays_or_starts_a_game_next() {
        let (state, _, tasks) = room().await;
        let next = |profile: &str, game: &str, start: bool| {
            next(
                State(state.clone()),
                Json(NextRequest {
                    profile: profile.into(),
                    game: game.into(),
                    start,
                }),
            )
        };
        let Json(view) = next("phone", "test", false).await.unwrap();
        let view = serde_json::to_value(view).unwrap();
        assert_eq!(view["next"], "test");
        assert!(next("phone", "test", true).await.is_ok());
        assert_eq!(
            next("phone", "elsewhere", true).await.unwrap_err(),
            StatusCode::CONFLICT
        );
        assert_eq!(
            next("stranger", "test", true).await.unwrap_err(),
            StatusCode::FORBIDDEN
        );
        tasks.iter().for_each(|t| t.abort());
    }

    #[tokio::test]
    async fn settings_can_be_read_for_the_warm_game_by_name() {
        let (state, _, tasks) = room().await;
        let for_game = |game: &str| {
            get_settings(
                State(state.clone()),
                Query(ProfileQuery {
                    profile: "phone".into(),
                    game: Some(game.into()),
                }),
            )
        };
        let Json(Some(controls)) = for_game("test").await.unwrap() else {
            panic!("the warm game declared settings")
        };
        assert_eq!(controls["game"], "test");
        let Json(none) = for_game("elsewhere").await.unwrap();
        assert!(none.is_none());
        tasks.iter().for_each(|t| t.abort());
    }

    #[tokio::test]
    async fn linked_phone_reads_and_changes_settings_as_its_own_player() {
        let (state, player, tasks) = room().await;
        assert_eq!(
            get_settings(State(state.clone()), profile("stranger"))
                .await
                .unwrap_err(),
            StatusCode::FORBIDDEN
        );
        let Json(Some(controls)) = get_settings(State(state.clone()), profile("phone"))
            .await
            .unwrap()
        else {
            panic!("the warm game declared settings")
        };
        assert_eq!(controls["game"], "test");
        assert_eq!(controls["settings"]["items"]["kind"], "toggle");
        assert_eq!(controls["settings"]["stock"]["max"], 9);
        let request = |profile: &str, command: Value| {
            set_settings(
                State(state.clone()),
                Json(SettingsRequest {
                    profile: profile.into(),
                    command: serde_json::from_value(command).unwrap(),
                }),
            )
        };
        let set = json!({"action":"set","instance":controls["instance"],
            "expected_revision":controls["revision"],"values":{"items":false,"stock":5}});
        assert_eq!(
            request("stranger", set.clone()).await.status(),
            StatusCode::FORBIDDEN
        );
        let response = request("phone", set.clone()).await;
        assert_eq!(response.status(), StatusCode::OK);
        let Json(Some(changed)) = get_settings(State(state.clone()), profile("phone"))
            .await
            .unwrap()
        else {
            panic!("settings disappeared")
        };
        assert_eq!(changed["settings"]["items"]["value"], false);
        assert_eq!(changed["settings"]["stock"]["value"], 5);
        assert_eq!(changed["can_undo"], true);
        // A stale revision is refused, with the daemon's reason.
        let stale = request("phone", set).await;
        assert_eq!(stale.status(), StatusCode::CONFLICT);
        let body = axum::body::to_bytes(stale.into_body(), 4096).await.unwrap();
        assert!(serde_json::from_slice::<Value>(&body).unwrap()["error"].is_string());
        // Out of range values are refused too.
        let wild = json!({"action":"set","instance":changed["instance"],
            "expected_revision":changed["revision"],"values":{"stock":50}});
        assert_eq!(request("phone", wild).await.status(), StatusCode::CONFLICT);
        let undo = json!({"action":"undo","instance":changed["instance"],
            "expected_revision":changed["revision"]});
        assert_eq!(request("phone", undo).await.status(), StatusCode::OK);
        let Json(Some(undone)) = get_settings(State(state.clone()), profile("phone"))
            .await
            .unwrap()
        else {
            panic!("settings disappeared")
        };
        assert_eq!(undone["settings"]["items"]["value"], true);
        // A relinked character no longer belongs to the phone's old link.
        state.lock().unwrap().link_revisions.insert(player, 7);
        let again = json!({"action":"set","instance":undone["instance"],
            "expected_revision":undone["revision"],"values":{"items":false}});
        assert_eq!(
            request("phone", again).await.status(),
            StatusCode::OK,
            "the binding, not a revision the phone sends, decides who it is"
        );
        tasks.iter().for_each(|t| t.abort());
    }
}
