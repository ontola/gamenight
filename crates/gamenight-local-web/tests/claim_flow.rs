//! End-to-end: the web studio's two ways into a party, against a real daemon
//! over a real socket and a real HTTP server.
//!
//! The distinction under test is the one that made a phone profile look like
//! it did nothing in the lobby. `POST .../join` with no `claim` adds a new
//! party member — but a member with no controller never spawns a character in
//! the lobby (`match_plugin_for_seats` deactivates any seat without a confirmed
//! pad), so from the couch it's invisible. Scanning the QR above a
//! character's head sends `claim=<player_id>` instead, which must *rename and
//! recolor that existing character* rather than add a second one.

use futures_util::{SinkExt, StreamExt};
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio_tungstenite::tungstenite::Message;

use gamenight_local_web::{create_router, Profile, ServerState};
use gamenight_protocol::{ClientMessage, PartySnapshot, PlayerId, Role, ServerMessage};

/// Spawn a daemon on an ephemeral port. Empty library so nothing auto-fills
/// the playlist underneath the assertions.
async fn start_daemon() -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap().to_string();
    tokio::spawn(gamenight_daemon::run_with_library(listener, Vec::new()));
    addr
}

/// Spawn the web server on an ephemeral port.
async fn start_server(daemon: &str) -> String {
    let state = Arc::new(Mutex::new(ServerState::new(daemon.to_owned())));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap().to_string();
    tokio::spawn(async move {
        axum::serve(listener, create_router(state)).await.unwrap();
    });
    addr
}

/// Minimal HTTP POST — keeps this a genuine over-the-wire test without
/// dragging an HTTP client into the dependency tree.
async fn post(addr: &str, path: &str, body: &str) -> (u16, String) {
    http(addr, "POST", path, body).await
}

async fn http(addr: &str, method: &str, path: &str, body: &str) -> (u16, String) {
    let mut stream = TcpStream::connect(addr).await.unwrap();
    let req = format!(
        "{method} {path} HTTP/1.1\r\nHost: {addr}\r\nContent-Type: application/json\r\n\
         Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream.write_all(req.as_bytes()).await.unwrap();
    let mut raw = String::new();
    stream.read_to_string(&mut raw).await.unwrap();
    let status = raw
        .split_whitespace()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    let body = raw.split("\r\n\r\n").nth(1).unwrap_or("").to_string();
    (status, body)
}

/// An overlay connection, which is the only role the daemon broadcasts party
/// snapshots to.
struct Watcher {
    ws: tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
    party: PartySnapshot,
}

impl Watcher {
    async fn connect(addr: &str) -> Self {
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
        let party = loop {
            if let Message::Text(t) = ws.next().await.unwrap().unwrap() {
                match serde_json::from_str::<ServerMessage>(&t).unwrap() {
                    ServerMessage::Welcome { party, .. } => break party,
                    _ => continue,
                }
            }
        };
        Self { ws, party }
    }

    /// Pump snapshots until `pred` holds. Every state change is broadcast, so
    /// this converges rather than polling.
    async fn wait_for(&mut self, pred: impl Fn(&PartySnapshot) -> bool) -> PartySnapshot {
        if pred(&self.party) {
            return self.party.clone();
        }
        loop {
            if let Message::Text(t) = self.ws.next().await.unwrap().unwrap() {
                if let ServerMessage::PartyState { party } =
                    serde_json::from_str::<ServerMessage>(&t).unwrap()
                {
                    self.party = party;
                    if pred(&self.party) {
                        return self.party.clone();
                    }
                }
            }
        }
    }
}

fn profile_json(id: &str, username: &str, color: &str, avatar: &str) -> String {
    serde_json::to_string(&Profile {
        id: id.into(),
        username: username.into(),
        color: color.into(),
        avatar: avatar.into(),
    })
    .unwrap()
}

/// The plain path: no `claim`, so a new party member appears.
#[tokio::test]
async fn join_without_claim_adds_a_player() {
    let daemon = start_daemon().await;
    let server = start_server(&daemon).await;
    let mut watcher = Watcher::connect(&daemon).await;
    assert_eq!(watcher.party.players.len(), 0, "party starts empty");

    let (status, _) = post(
        &server,
        "/api/profiles",
        &profile_json("p1", "Ada", "#ff0000", "avatar-a"),
    )
    .await;
    assert_eq!(status, 200);

    let (status, body) = post(
        &server,
        "/api/profiles/p1/join",
        &format!(r#"{{"daemon_addr":"{daemon}"}}"#),
    )
    .await;
    assert_eq!(status, 200, "join failed: {body}");
    assert!(body.contains("\"joined\""), "expected joined, got {body}");

    let party = watcher.wait_for(|p| !p.players.is_empty()).await;
    assert_eq!(party.players.len(), 1);
    assert_eq!(party.players[0].name, "Ada");
    assert_eq!(party.players[0].color.as_deref(), Some("#ff0000"));
    assert_eq!(party.players[0].avatar.as_deref(), Some("avatar-a"));
}

/// The head-QR path: `claim` rewrites the character that already exists.
///
/// This is the regression that matters. Before `claim`, scanning the QR above
/// your character ran the join path and produced a *second* party member —
/// leaving the body you walked up to still called "Panda" while your profile
/// sat in a seat with nothing spawned.
#[tokio::test]
async fn claim_rewrites_the_existing_player_instead_of_adding_one() {
    let daemon = start_daemon().await;
    let server = start_server(&daemon).await;
    let mut watcher = Watcher::connect(&daemon).await;

    // A controller-joined character already in the lobby: name and color, no
    // avatar (a pad can't draw one) — exactly what the lobby treats as unclaimed.
    let mut pad = Watcher::connect(&daemon).await;
    pad.ws
        .send(Message::Text(
            ClientMessage::JoinParty {
                name: "Panda".into(),
                seat: None,
                color: Some("#5c9eff".into()),
                avatar: None,
                library: Vec::new(),
            }
            .to_json(),
        ))
        .await
        .unwrap();

    let party = watcher.wait_for(|p| !p.players.is_empty()).await;
    assert_eq!(party.players.len(), 1);
    let target: PlayerId = party.players[0].id;
    assert_eq!(party.players[0].name, "Panda");
    assert!(
        party.players[0].avatar.is_none(),
        "a pad-joined player must start unclaimed, or the lobby hides its QR"
    );

    post(
        &server,
        "/api/profiles",
        &profile_json("p2", "Grace", "#00ff00", "avatar-g"),
    )
    .await;

    let (status, body) = post(
        &server,
        "/api/profiles/p2/join",
        &format!(r#"{{"daemon_addr":"{daemon}","claim":"{}"}}"#, target.0),
    )
    .await;
    assert_eq!(status, 200, "claim failed: {body}");
    assert!(body.contains("\"claimed\""), "expected claimed, got {body}");

    // Rename/color/avatar are three separate messages, so the daemon
    // broadcasts three times. Wait for the last of them to land, not the
    // first, or this races the state it's asserting on.
    let party = watcher
        .wait_for(|p| {
            p.players.iter().any(|pl| {
                pl.name == "Grace"
                    && pl.color.as_deref() == Some("#00ff00")
                    && pl.avatar.as_deref() == Some("avatar-g")
            })
        })
        .await;

    // The whole point: same player, new identity — not a second one.
    assert_eq!(
        party.players.len(),
        1,
        "claim must not add a player, got {:?}",
        party.players
    );
    let claimed = &party.players[0];
    assert_eq!(claimed.id, target, "claim must rewrite the same player id");
    assert_eq!(claimed.name, "Grace");
    assert_eq!(claimed.color.as_deref(), Some("#00ff00"));
    assert_eq!(
        claimed.avatar.as_deref(),
        Some("avatar-g"),
        "avatar is what marks the character claimed, so its QR disappears"
    );
}

/// The seat keeps its occupant across a claim — the character on screen is
/// the same body, so it must not be re-seated or ejected.
#[tokio::test]
async fn claim_keeps_the_players_seat() {
    let daemon = start_daemon().await;
    let server = start_server(&daemon).await;
    let mut watcher = Watcher::connect(&daemon).await;

    let mut pad = Watcher::connect(&daemon).await;
    pad.ws
        .send(Message::Text(
            ClientMessage::JoinParty {
                name: "Ninja".into(),
                seat: None,
                color: Some("#a78bfa".into()),
                avatar: None,
                library: Vec::new(),
            }
            .to_json(),
        ))
        .await
        .unwrap();

    let party = watcher.wait_for(|p| !p.players.is_empty()).await;
    let target = party.players[0].id;
    let seat_before = party
        .seats
        .iter()
        .find(|s| s.occupant.player_id() == Some(target))
        .map(|s| s.index)
        .expect("a joined player holds a seat");

    post(
        &server,
        "/api/profiles",
        &profile_json("p3", "Turing", "#123456", "avatar-t"),
    )
    .await;
    post(
        &server,
        "/api/profiles/p3/join",
        &format!(r#"{{"daemon_addr":"{daemon}","claim":"{}"}}"#, target.0),
    )
    .await;

    let party = watcher
        .wait_for(|p| p.players.iter().any(|pl| pl.name == "Turing"))
        .await;
    let seat_after = party
        .seats
        .iter()
        .find(|s| s.occupant.player_id() == Some(target))
        .map(|s| s.index);
    assert_eq!(
        seat_after,
        Some(seat_before),
        "claiming must not move the character to another seat"
    );
}

/// Claiming an id nobody holds must not invent a player.
#[tokio::test]
async fn claiming_an_unknown_player_adds_nobody() {
    let daemon = start_daemon().await;
    let server = start_server(&daemon).await;
    let mut watcher = Watcher::connect(&daemon).await;

    post(
        &server,
        "/api/profiles",
        &profile_json("p4", "Nobody", "#ffffff", "avatar-n"),
    )
    .await;
    let (status, _) = post(
        &server,
        "/api/profiles/p4/join",
        &format!(
            r#"{{"daemon_addr":"{daemon}","claim":"{}"}}"#,
            PlayerId::new().0
        ),
    )
    .await;
    assert_eq!(status, 200);

    // Give the daemon a moment to have done the wrong thing, if it were going to.
    let mut probe = Watcher::connect(&daemon).await;
    probe
        .ws
        .send(Message::Text(
            ClientMessage::JoinParty {
                name: "Marker".into(),
                seat: None,
                color: None,
                avatar: None,
                library: Vec::new(),
            }
            .to_json(),
        ))
        .await
        .unwrap();
    let party = watcher
        .wait_for(|p| p.players.iter().any(|pl| pl.name == "Marker"))
        .await;

    assert!(
        !party.players.iter().any(|p| p.name == "Nobody"),
        "a claim for an unknown id must not create a player, got {:?}",
        party.players
    );
}

/// Minimal HTTP GET, same reasoning as `post`.
async fn get(addr: &str, path: &str) -> (u16, String) {
    let mut stream = TcpStream::connect(addr).await.unwrap();
    let req = format!("GET {path} HTTP/1.1\r\nHost: {addr}\r\nConnection: close\r\n\r\n");
    stream.write_all(req.as_bytes()).await.unwrap();
    let mut raw = String::new();
    // The studio page isn't valid UTF-8-safe to assume, but it is ASCII HTML.
    let mut buf = Vec::new();
    stream.read_to_end(&mut buf).await.unwrap();
    raw.push_str(&String::from_utf8_lossy(&buf));
    let status = raw
        .split_whitespace()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    let body = raw.split("\r\n\r\n").nth(1).unwrap_or("").to_string();
    (status, body)
}

/// The two halves of the claim flow have to agree on the URL shape. The lobby
/// renders `<join_url>?claim=<player_id>` onto the QR above a character's
/// head; that has to land on the studio page, and that page has to actually
/// read the parameter back out. A silent mismatch here would look exactly
/// like "scanning the QR does nothing".
#[tokio::test]
async fn session_url_with_claim_serves_a_studio_that_reads_it() {
    let server = start_server("127.0.0.1:7912").await;
    let player = PlayerId::new();

    let (status, body) = get(&server, &format!("/session/gn-couch?claim={}", player.0)).await;
    assert_eq!(status, 200, "the claim URL must serve the studio");
    assert!(
        body.contains("claimPlayerId"),
        "the studio page must parse the claim parameter"
    );
    assert!(
        body.contains("get('claim')"),
        "the studio page must read `claim` from the query string"
    );
    assert!(
        body.contains("claimPlayerId || boundPlayerId"),
        "the page must prefer a scanned character, then the one it already joined"
    );
    assert!(
        body.contains("claim: target"),
        "the studio page must forward the claim id to the join endpoint"
    );
}

/// A fresh join must report the player it created.
///
/// This is what makes save-on-every-keystroke safe: the studio keeps the id
/// and sends it as `claim` from then on, so the second edit updates that
/// player. Without it, every autosave would be another `JoinParty` and one
/// person typing their name would fill the party with duplicates.
#[tokio::test]
async fn join_reports_the_player_it_created_and_repeats_dont_duplicate() {
    let daemon = start_daemon().await;
    let server = start_server(&daemon).await;
    let mut watcher = Watcher::connect(&daemon).await;

    post(
        &server,
        "/api/profiles",
        &profile_json("auto", "Ada", "#ff0000", "avatar-a"),
    )
    .await;

    let (status, body) = post(
        &server,
        "/api/profiles/auto/join",
        &format!(r#"{{"daemon_addr":"{daemon}"}}"#),
    )
    .await;
    assert_eq!(status, 200, "join failed: {body}");

    let json: serde_json::Value = serde_json::from_str(&body).unwrap();
    let player_id = json["player_id"]
        .as_str()
        .expect("join must report the new player's id");

    let party = watcher.wait_for(|p| !p.players.is_empty()).await;
    assert_eq!(party.players.len(), 1);
    assert_eq!(
        party.players[0].id.0.to_string(),
        player_id,
        "the reported id must be the player that was actually created"
    );

    // Now the autosave path: same profile, edited, sent back with the id.
    post(
        &server,
        "/api/profiles",
        &profile_json("auto", "Ada Lovelace", "#00ff00", "avatar-b"),
    )
    .await;
    let (status, _) = post(
        &server,
        "/api/profiles/auto/join",
        &format!(r#"{{"daemon_addr":"{daemon}","claim":"{player_id}"}}"#),
    )
    .await;
    assert_eq!(status, 200);

    let party = watcher
        .wait_for(|p| {
            p.players.iter().any(|pl| {
                pl.name == "Ada Lovelace"
                    && pl.color.as_deref() == Some("#00ff00")
                    && pl.avatar.as_deref() == Some("avatar-b")
            })
        })
        .await;
    assert_eq!(
        party.players.len(),
        1,
        "repeated saves must update, not duplicate, got {:?}",
        party.players
    );
}

/// Claiming by *seat* resolves to whoever is sitting there now.
///
/// This is what the wall QR encodes. A seat index survives the daemon
/// clearing `players` when the lobby process restarts, whereas a player id
/// does not — an id-bearing code printed before a restart silently aimed at
/// a deleted player, which is indistinguishable from success.
#[tokio::test]
async fn claiming_by_seat_resolves_to_the_current_occupant() {
    let daemon = start_daemon().await;
    let server = start_server(&daemon).await;
    let mut watcher = Watcher::connect(&daemon).await;

    let mut pad = Watcher::connect(&daemon).await;
    pad.ws
        .send(Message::Text(
            ClientMessage::JoinParty {
                name: "Waffle".into(),
                seat: None,
                color: Some("#5c9eff".into()),
                avatar: None,
                library: Vec::new(),
            }
            .to_json(),
        ))
        .await
        .unwrap();

    let party = watcher.wait_for(|p| !p.players.is_empty()).await;
    let target = party.players[0].id;
    let seat = party
        .seats
        .iter()
        .find(|s| s.occupant.player_id() == Some(target))
        .map(|s| s.index)
        .expect("a joined player holds a seat");

    post(
        &server,
        "/api/profiles",
        &profile_json("bySeat", "Grace", "#00ff00", "avatar-g"),
    )
    .await;
    let (status, body) = post(
        &server,
        "/api/profiles/bySeat/join",
        &format!(r#"{{"daemon_addr":"{daemon}","seat":{seat}}}"#),
    )
    .await;
    assert_eq!(status, 200, "seat claim failed: {body}");
    assert!(body.contains("\"claimed\""), "expected claimed, got {body}");

    let party = watcher
        .wait_for(|p| {
            p.players
                .iter()
                .any(|pl| pl.name == "Grace" && pl.avatar.as_deref() == Some("avatar-g"))
        })
        .await;
    assert_eq!(party.players.len(), 1, "must rewrite, not add");
    assert_eq!(party.players[0].id, target, "must be the seat's occupant");
}

/// An empty seat must say so rather than reporting success.
///
/// The silent version of this cost a long debugging session: the studio
/// showed "saved", the daemon logged a connect/disconnect, and nothing
/// anywhere said the target didn't exist.
#[tokio::test]
async fn claiming_an_empty_seat_reports_it() {
    let daemon = start_daemon().await;
    let server = start_server(&daemon).await;

    post(
        &server,
        "/api/profiles",
        &profile_json("empty", "Nobody", "#ffffff", "avatar-n"),
    )
    .await;
    let (status, body) = post(
        &server,
        "/api/profiles/empty/join",
        &format!(r#"{{"daemon_addr":"{daemon}","seat":3}}"#),
    )
    .await;
    assert_eq!(status, 200);
    assert!(
        body.contains("no_such_seat"),
        "an empty seat must be reported, got {body}"
    );

    // …and must not have quietly added a player instead.
    let watcher = Watcher::connect(&daemon).await;
    assert!(
        watcher.party.players.is_empty(),
        "a failed seat claim must not add anyone, got {:?}",
        watcher.party.players
    );
}

/// One device is one person: a profile already signed in as a live player
/// cannot claim a second seat.
///
/// Without this, a phone could scan the wall QR, walk to the next sign-in pad,
/// scan again, and end up driving two characters with the same name and face —
/// which also quietly takes a seat from someone who hasn't sat down yet.
#[tokio::test]
async fn one_profile_cannot_hold_two_seats() {
    let daemon = start_daemon().await;
    let server = start_server(&daemon).await;
    let mut watcher = Watcher::connect(&daemon).await;

    // Two pad-joined characters, as if two people pressed Start.
    let mut pads = Watcher::connect(&daemon).await;
    for name in ["Comet", "Biscuit"] {
        pads.ws
            .send(Message::Text(
                ClientMessage::JoinParty {
                    name: name.into(),
                    seat: None,
                    color: Some("#5c9eff".into()),
                    avatar: None,
                    library: Vec::new(),
                }
                .to_json(),
            ))
            .await
            .unwrap();
    }
    let party = watcher.wait_for(|p| p.players.len() == 2).await;
    let seats: Vec<u8> = party
        .seats
        .iter()
        .filter(|s| s.occupant.player_id().is_some())
        .map(|s| s.index)
        .collect();
    assert_eq!(seats.len(), 2, "two characters must hold two seats");

    post(
        &server,
        "/api/profiles",
        &profile_json("phone", "Joep", "#00ff00", "avatar-j"),
    )
    .await;

    // First seat: fine.
    let (status, body) = post(
        &server,
        "/api/profiles/phone/join",
        &format!(r#"{{"daemon_addr":"{daemon}","seat":{}}}"#, seats[0]),
    )
    .await;
    assert_eq!(status, 200);
    assert!(
        body.contains("\"claimed\""),
        "first claim should work: {body}"
    );

    let party = watcher
        .wait_for(|p| p.players.iter().any(|pl| pl.name == "Joep"))
        .await;
    assert_eq!(party.players.len(), 2, "still two players");

    // Second seat from the same profile: refused, and told why.
    let (status, body) = post(
        &server,
        "/api/profiles/phone/join",
        &format!(r#"{{"daemon_addr":"{daemon}","seat":{}}}"#, seats[1]),
    )
    .await;
    assert_eq!(status, 200);
    assert!(
        body.contains("already_signed_in"),
        "a second seat must be refused, got {body}"
    );

    // And the other character must be untouched.
    let check = Watcher::connect(&daemon).await;
    let names: Vec<&str> = check
        .party
        .players
        .iter()
        .map(|p| p.name.as_str())
        .collect();
    assert_eq!(
        names.iter().filter(|n| **n == "Joep").count(),
        1,
        "exactly one character may carry this profile, got {names:?}"
    );
}

/// Re-claiming the seat you already hold is the ordinary autosave path and
/// must keep working — the guard is about *different* seats, not repeats.
#[tokio::test]
async fn re_claiming_your_own_seat_still_works() {
    let daemon = start_daemon().await;
    let server = start_server(&daemon).await;
    let mut watcher = Watcher::connect(&daemon).await;

    let mut pad = Watcher::connect(&daemon).await;
    pad.ws
        .send(Message::Text(
            ClientMessage::JoinParty {
                name: "Comet".into(),
                seat: None,
                color: Some("#5c9eff".into()),
                avatar: None,
                library: Vec::new(),
            }
            .to_json(),
        ))
        .await
        .unwrap();
    let party = watcher.wait_for(|p| !p.players.is_empty()).await;
    let seat = party
        .seats
        .iter()
        .find_map(|s| s.occupant.player_id().map(|_| s.index))
        .unwrap();

    post(
        &server,
        "/api/profiles",
        &profile_json("repeat", "Ada", "#ff0000", "avatar-a"),
    )
    .await;
    for expected in ["Ada", "Ada Again"] {
        post(
            &server,
            "/api/profiles",
            &profile_json("repeat", expected, "#ff0000", "avatar-a"),
        )
        .await;
        let (status, body) = post(
            &server,
            "/api/profiles/repeat/join",
            &format!(r#"{{"daemon_addr":"{daemon}","seat":{seat}}}"#),
        )
        .await;
        assert_eq!(status, 200);
        assert!(
            body.contains("\"claimed\""),
            "re-claiming your own seat must succeed, got {body}"
        );
    }

    let party = watcher
        .wait_for(|p| p.players.iter().any(|pl| pl.name == "Ada Again"))
        .await;
    assert_eq!(party.players.len(), 1, "no duplicate was created");
}

#[tokio::test]
async fn local_studio_excludes_commerce() {
    let server = start_server("127.0.0.1:7912").await;
    assert_eq!(get(&server, "/api/store").await.0, 404);
    assert_eq!(
        post(&server, "/api/profiles/test/buy", r#"{"game_id":"demo"}"#)
            .await
            .0,
        404
    );
    let (status, body) = get(&server, "/studio").await;
    assert_eq!(status, 200);
    for removed in ["buyGame", "owned_games", "tab-store", "/api/store"] {
        assert!(
            !body.contains(removed),
            "commerce leaked into studio: {removed}"
        );
    }
}

async fn save_test_profile(server: &str) {
    let (status, _) = post(
        server,
        "/api/profiles",
        r##"{"id":"failure-test","username":"Ada","color":"#ff0000","avatar":""}"##,
    )
    .await;
    assert_eq!(status, 200);
}

#[tokio::test]
async fn disconnected_daemon_does_not_report_a_successful_join() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let server = start_server(&listener.local_addr().unwrap().to_string()).await;
    let peer = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut ws = tokio_tungstenite::accept_async(stream).await.unwrap();
        assert!(matches!(ws.next().await, Some(Ok(Message::Text(_)))));
        ws.close(None).await.unwrap();
    });
    save_test_profile(&server).await;
    let (status, _) = post(&server, "/api/profiles/failure-test/join", "{}").await;
    assert_eq!(status, 502);
    peer.await.unwrap();
}

#[tokio::test]
async fn silent_daemon_times_out_without_receiving_join_commands() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let server = start_server(&listener.local_addr().unwrap().to_string()).await;
    let peer = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut ws = tokio_tungstenite::accept_async(stream).await.unwrap();
        assert!(matches!(ws.next().await, Some(Ok(Message::Text(_)))));
        // Keep the socket alive, but never send the required Welcome.
        assert!(!matches!(ws.next().await, Some(Ok(Message::Text(_)))));
    });
    save_test_profile(&server).await;
    let (status, _) = tokio::time::timeout(
        std::time::Duration::from_secs(5),
        post(&server, "/api/profiles/failure-test/join", "{}"),
    )
    .await
    .expect("HTTP request must be bounded");
    assert_eq!(status, 504);
    peer.await.unwrap();
}

#[tokio::test]
async fn browser_cannot_override_the_host_daemon_address() {
    let daemon = start_daemon().await;
    let server = start_server(&daemon).await;
    let mut watcher = Watcher::connect(&daemon).await;
    save_test_profile(&server).await;
    let (status, _) = post(
        &server,
        "/api/profiles/failure-test/join",
        r#"{"daemon_addr":"127.0.0.1:1"}"#,
    )
    .await;
    assert_eq!(status, 200);
    let party = watcher.wait_for(|party| !party.players.is_empty()).await;
    assert_eq!(party.players[0].name, "Ada");
}

#[tokio::test]
async fn playlist_move_is_live_and_rejects_stale_or_invalid_positions() {
    use gamenight_protocol::{GameId, PlaylistEntry};
    let daemon = start_daemon().await;
    let server = start_server(&daemon).await;
    let mut watcher = Watcher::connect(&daemon).await;
    watcher
        .ws
        .send(Message::Text(
            ClientMessage::SetPlaylist {
                entries: ["a", "b", "c"]
                    .into_iter()
                    .map(|id| PlaylistEntry {
                        game: GameId::new(id),
                        title: id.into(),
                    })
                    .collect(),
            }
            .to_json(),
        ))
        .await
        .unwrap();
    let party = watcher.wait_for(|p| p.playlist.entries.len() == 3).await;
    let (status, body) = http(&server, "GET", "/api/playlist", "").await;
    assert_eq!(status, 200);
    let initial: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(
        initial["playlist"],
        serde_json::to_value(&party.playlist).unwrap()
    );
    let request = serde_json::json!({ "expected": party.playlist, "from": 2, "to": 0 }).to_string();
    let (status, body) = post(&server, "/api/playlist", &request).await;
    assert_eq!(status, 200, "{body}");
    let view: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert_eq!(view["playlist"]["entries"][0]["game"], "c");
    assert!(view.get("library").is_none());
    assert_eq!(post(&server, "/api/playlist", &request).await.0, 409);
    let request =
        serde_json::json!({ "expected": view["playlist"], "from": 99, "to": 0 }).to_string();
    assert_eq!(post(&server, "/api/playlist", &request).await.0, 400);
    watcher
        .wait_for(|p| p.playlist.entries[0].game == GameId::new("c"))
        .await;
}

#[tokio::test]
async fn web_reorder_broadcasts_the_new_up_next_to_the_lobby() {
    use gamenight_protocol::{GameId, PlaylistEntry, SessionPhase};
    tokio::time::timeout(std::time::Duration::from_secs(5), async {
        let daemon = start_daemon().await;
        let server = start_server(&daemon).await;
        let mut lobby = Watcher::connect(&daemon).await;
        let mut games = Vec::new();
        for id in ["a", "b", "c"] {
            let (mut ws, _) = tokio_tungstenite::connect_async(format!("ws://{daemon}"))
                .await
                .unwrap();
            ws.send(Message::Text(
                ClientMessage::Hello {
                    role: Role::Game,
                    game: Some(GameId::new(id)),
                    token: None,
                }
                .to_json(),
            ))
            .await
            .unwrap();
            games.push(ws);
        }
        lobby.wait_for(|p| p.connected_games.len() == 3).await;
        lobby
            .ws
            .send(Message::Text(
                ClientMessage::SetPlaylist {
                    entries: ["a", "b", "c"]
                        .into_iter()
                        .map(|id| PlaylistEntry {
                            game: GameId::new(id),
                            title: id.into(),
                        })
                        .collect(),
                }
                .to_json(),
            ))
            .await
            .unwrap();
        let party = lobby.wait_for(|p| p.warm_session.is_some()).await;
        let first = party.warm_session.unwrap().id;
        games[0]
            .send(Message::Text(
                ClientMessage::Ready { session: first }.to_json(),
            ))
            .await
            .unwrap();
        let before = lobby
            .wait_for(|p| p.active_session.is_some() && p.warm_session.is_some())
            .await;
        let request =
            serde_json::json!({"expected": before.playlist, "from": 2, "to": 1}).to_string();
        let (status, body) = post(&server, "/api/playlist", &request).await;
        assert_eq!(status, 200, "{body}");
        let view: serde_json::Value = serde_json::from_str(&body).unwrap();
        assert_eq!(view["next"], "c");
        let updated = lobby
            .wait_for(|p| {
                p.warm_session
                    .as_ref()
                    .is_some_and(|s| s.game == GameId::new("c"))
            })
            .await;
        assert_eq!(updated.active_session.unwrap().id, first);
        games[2]
            .send(Message::Text(
                ClientMessage::Ready {
                    session: updated.warm_session.unwrap().id,
                }
                .to_json(),
            ))
            .await
            .unwrap();
        lobby
            .wait_for(|p| {
                p.warm_session
                    .as_ref()
                    .is_some_and(|s| s.phase == SessionPhase::Ready)
            })
            .await;
        let (status, body) = http(&server, "GET", "/api/playlist", "").await;
        assert_eq!(status, 200);
        let ready: serde_json::Value = serde_json::from_str(&body).unwrap();
        assert_eq!(ready["next"], "c");
        assert_eq!(ready["playing"], "a");
    })
    .await
    .expect("playlist update must reach the lobby promptly");
}

#[tokio::test]
async fn opted_in_game_receives_a_new_controller_without_a_new_session() {
    use gamenight_protocol::{GameId, PlaylistEntry};
    tokio::time::timeout(std::time::Duration::from_secs(5), async {
        let addr = start_daemon().await;
        let mut overlay = Watcher::connect(&addr).await;
        let (mut game, _) = tokio_tungstenite::connect_async(format!("ws://{addr}"))
            .await
            .unwrap();
        game.send(Message::Text(
            ClientMessage::Hello {
                role: Role::Game,
                game: Some(GameId::new("arena")),
                token: None,
            }
            .to_json(),
        ))
        .await
        .unwrap();
        overlay.wait_for(|p| !p.connected_games.is_empty()).await;
        overlay
            .ws
            .send(Message::Text(
                ClientMessage::SetPlaylist {
                    entries: vec![PlaylistEntry {
                        game: GameId::new("arena"),
                        title: "Arena".into(),
                    }],
                }
                .to_json(),
            ))
            .await
            .unwrap();
        let party = overlay.wait_for(|p| p.warm_session.is_some()).await;
        let session = party.warm_session.unwrap().id;
        game.send(Message::Text(
            ClientMessage::Participation {
                session,
                instant_join: true,
            }
            .to_json(),
        ))
        .await
        .unwrap();
        game.send(Message::Text(ClientMessage::Ready { session }.to_json()))
            .await
            .unwrap();
        overlay.wait_for(|p| p.active_session.is_some()).await;
        game.send(Message::Text(
            ClientMessage::ControllerInput {
                session: Some(session),
                controller: "ordinal:2".into(),
            }
            .to_json(),
        ))
        .await
        .unwrap();
        let party = overlay.wait_for(|p| p.players.len() == 1).await;
        let player = party.players[0].id;
        assert_eq!(party.active_session.unwrap().id, session);
        assert_eq!(party.seats[0].controller.as_deref(), Some("ordinal:2"));
        loop {
            if let Message::Text(text) = game.next().await.unwrap().unwrap() {
                if let ServerMessage::PartyUpdated {
                    session: update,
                    players,
                    presence,
                    ..
                } = serde_json::from_str(&text).unwrap()
                {
                    if players.len() == 1 {
                        assert_eq!(update, session);
                        assert_eq!(players[0].id, player);
                        assert_eq!(presence[0].player_id, player);
                        break;
                    }
                }
            }
        }
    })
    .await
    .expect("live join must reach the running game promptly");
}
