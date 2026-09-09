//! End-to-end: a real daemon on a real socket, two games speaking the SDK,
//! and an overlay driving the party — one continuous night.

use futures_util::{SinkExt, StreamExt};
use tokio::net::{TcpListener, TcpStream};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};

use gamenight_protocol::{
    ClientMessage, GameId, PartySnapshot, PlaylistEntry, Role, ServerMessage, SessionPhase,
    VoteOption,
};
use gamenight_sdk::{GameEvent, GameNight};

type Ws = WebSocketStream<MaybeTlsStream<TcpStream>>;

async fn start_daemon() -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap().to_string();
    // Empty library: these tests build their own playlist from scratch and
    // assert on exact prepare/dispose sequencing, which the demo shelf's
    // library-derived auto-fill (gamenight-core's `set_library`) would
    // otherwise race with.
    tokio::spawn(gamenight_daemon::run_with_library(listener, Vec::new()));
    addr
}

/// A minimal overlay client for tests.
struct Overlay {
    ws: Ws,
    party: PartySnapshot,
}

impl Overlay {
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
        let party = match Self::recv_raw(&mut ws).await {
            ServerMessage::Welcome { party, .. } => party,
            other => panic!("expected welcome, got {other:?}"),
        };
        Self { ws, party }
    }

    async fn recv_raw(ws: &mut Ws) -> ServerMessage {
        loop {
            match ws.next().await.expect("daemon closed").unwrap() {
                Message::Text(text) => return serde_json::from_str(&text).unwrap(),
                _ => continue,
            }
        }
    }

    async fn send(&mut self, msg: ClientMessage) {
        self.ws.send(Message::Text(msg.to_json())).await.unwrap();
    }

    /// Receive snapshots until `pred` holds (all state changes are broadcast).
    async fn wait_for(&mut self, pred: impl Fn(&PartySnapshot) -> bool) -> PartySnapshot {
        if pred(&self.party) {
            return self.party.clone();
        }
        loop {
            match Self::recv_raw(&mut self.ws).await {
                ServerMessage::PartyState { party } => {
                    self.party = party;
                    if pred(&self.party) {
                        return self.party.clone();
                    }
                }
                ServerMessage::Error { message } => panic!("daemon error: {message}"),
                _ => continue,
            }
        }
    }
}

/// Drives one SDK game: prepares instantly, plays until told to finish.
struct TestGame {
    gn: GameNight,
}

impl TestGame {
    async fn connect(id: &str, addr: &str) -> Self {
        Self {
            gn: GameNight::connect(id, Some(addr)).await.unwrap(),
        }
    }

    /// Expect a Prepare and answer Ready.
    async fn prepare_and_ready(&mut self) -> gamenight_protocol::SessionId {
        match self.gn.next_event().await.unwrap() {
            Some(GameEvent::Prepare { session, .. }) => {
                self.gn.ready(session).await.unwrap();
                session
            }
            other => panic!("expected prepare, got {other:?}"),
        }
    }

    async fn expect_start(&mut self, session: gamenight_protocol::SessionId) {
        match self.gn.next_event().await.unwrap() {
            Some(GameEvent::Start { session: s }) if s == session => {}
            other => panic!("expected start of {session:?}, got {other:?}"),
        }
    }

    async fn expect_dispose(&mut self, session: gamenight_protocol::SessionId) {
        match self.gn.next_event().await.unwrap() {
            Some(GameEvent::Dispose { session: s }) if s == session => {}
            other => panic!("expected dispose of {session:?}, got {other:?}"),
        }
    }
}

fn entry(id: &str) -> PlaylistEntry {
    PlaylistEntry {
        game: GameId::new(id),
        title: id.to_string(),
    }
}

#[tokio::test]
async fn one_continuous_night() {
    let addr = start_daemon().await;

    // Two friends walk in and grab controllers.
    let mut overlay = Overlay::connect(&addr).await;
    overlay
        .send(ClientMessage::JoinParty {
            name: "Ada".into(),
            seat: None,
            color: None,
            avatar: None,
            library: Vec::new(),
        })
        .await;
    overlay
        .send(ClientMessage::JoinParty {
            name: "Joep".into(),
            seat: None,
            color: None,
            avatar: None,
            library: Vec::new(),
        })
        .await;
    let snap = overlay.wait_for(|p| p.players.len() == 2).await;
    let ada = snap.players[0].id;
    let joep = snap.players[1].id;
    assert_eq!(snap.seats[0].occupant.player_id(), Some(ada));
    assert_eq!(snap.seats[1].occupant.player_id(), Some(joep));

    // Two game processes are up.
    let mut towerfall = TestGame::connect("towerfall", &addr).await;
    let mut duck = TestGame::connect("duck-game", &addr).await;

    // Playlist chosen: towerfall warms, auto-starts, duck warms behind it.
    overlay
        .send(ClientMessage::SetPlaylist {
            entries: vec![entry("towerfall"), entry("duck-game")],
        })
        .await;
    let s1 = towerfall.prepare_and_ready().await;
    towerfall.expect_start(s1).await;
    let s2 = duck.prepare_and_ready().await;

    let snap = overlay
        .wait_for(|p| {
            p.active_session.as_ref().map(|s| s.phase) == Some(SessionPhase::Running)
                && p.warm_session.as_ref().map(|s| s.phase) == Some(SessionPhase::Ready)
        })
        .await;
    assert_eq!(snap.active_session.unwrap().game, GameId::new("towerfall"));
    assert_eq!(snap.warm_session.unwrap().game, GameId::new("duck-game"));

    // Match over: the vote opens on the overlay.
    towerfall.gn.finished(s1).await.unwrap();
    overlay
        .wait_for(|p| p.active_session.as_ref().map(|s| s.phase) == Some(SessionPhase::Finished))
        .await;

    // Both players stand on "next game" — instant transition.
    overlay
        .send(ClientMessage::Vote {
            player_id: ada,
            option: VoteOption::NextGame,
        })
        .await;
    overlay
        .send(ClientMessage::Vote {
            player_id: joep,
            option: VoteOption::NextGame,
        })
        .await;

    towerfall.expect_dispose(s1).await;
    duck.expect_start(s2).await;
    // The playlist wraps: towerfall warms again behind duck-game.
    let s3 = towerfall.prepare_and_ready().await;
    assert_ne!(s3, s1);

    let snap = overlay
        .wait_for(|p| {
            p.active_session.as_ref().map(|s| s.id) == Some(s2)
                && p.history == vec![GameId::new("towerfall")]
        })
        .await;
    assert_eq!(snap.playlist.current, Some(1));

    // Skip button: no vote needed, straight to towerfall round two.
    overlay.send(ClientMessage::Next).await;
    duck.expect_dispose(s2).await;
    towerfall.expect_start(s3).await;
    overlay
        .wait_for(|p| p.active_session.as_ref().map(|s| s.id) == Some(s3) && p.history.len() == 2)
        .await;
}

#[tokio::test]
async fn pause_and_resume_reach_the_game() {
    let addr = start_daemon().await;
    let mut overlay = Overlay::connect(&addr).await;
    let mut game = TestGame::connect("solo", &addr).await;

    overlay
        .send(ClientMessage::SetPlaylist {
            entries: vec![entry("solo")],
        })
        .await;
    let s1 = game.prepare_and_ready().await;
    game.expect_start(s1).await;

    overlay.send(ClientMessage::Pause).await;
    match game.gn.next_event().await.unwrap() {
        Some(GameEvent::Pause { session }) => assert_eq!(session, s1),
        other => panic!("expected pause, got {other:?}"),
    }
    overlay.send(ClientMessage::Resume).await;
    match game.gn.next_event().await.unwrap() {
        Some(GameEvent::Resume { session }) => assert_eq!(session, s1),
        other => panic!("expected resume, got {other:?}"),
    }
}

#[tokio::test]
async fn overlay_pauses_manages_seats_and_skips() {
    let addr = start_daemon().await;
    let mut overlay = Overlay::connect(&addr).await;
    let mut g1 = TestGame::connect("g1", &addr).await;
    let mut g2 = TestGame::connect("g2", &addr).await;

    overlay
        .send(ClientMessage::JoinParty {
            name: "Ada".into(),
            seat: Some(1),
            color: None,
            avatar: None,
            library: Vec::new(),
        })
        .await;
    let snap = overlay.wait_for(|p| p.players.len() == 1).await;
    let ada = snap.players[0].id;
    assert_eq!(snap.seats[1].occupant.player_id(), Some(ada));

    overlay
        .send(ClientMessage::SetPlaylist {
            entries: vec![entry("g1"), entry("g2")],
        })
        .await;
    let s1 = g1.prepare_and_ready().await;
    g1.expect_start(s1).await;
    let s2 = g2.prepare_and_ready().await;

    // Opening the party pauses the game on every screen.
    overlay.send(ClientMessage::OpenOverlay).await;
    match g1.gn.next_event().await.unwrap() {
        Some(GameEvent::Pause { session }) => assert_eq!(session, s1),
        other => panic!("expected pause, got {other:?}"),
    }
    let snap = overlay.wait_for(|p| p.overlay_open).await;
    assert_eq!(snap.active_session.unwrap().phase, SessionPhase::Paused);

    // While the overlay is up: Ada switches controllers (seat 1 -> seat 0).
    overlay.send(ClientMessage::SwapSeats { a: 1, b: 0 }).await;
    overlay
        .wait_for(|p| p.seats[0].occupant.player_id() == Some(ada))
        .await;

    // Changing seats disposes the stale warm session and prepares the next
    // game again with the new assignments before it can start.
    g2.expect_dispose(s2).await;
    let s2 = g2.prepare_and_ready().await;

    // Skip from the overlay: instant transition, overlay closes itself.
    overlay.send(ClientMessage::Next).await;
    g1.expect_dispose(s1).await;
    g2.expect_start(s2).await;
    let snap = overlay
        .wait_for(|p| p.active_session.as_ref().map(|s| s.id) == Some(s2))
        .await;
    assert!(!snap.overlay_open, "transition closes the overlay");
    assert_eq!(
        snap.active_session.unwrap().phase,
        SessionPhase::Running,
        "the new game starts running, not paused"
    );

    // Overlay again: pause g2, close without skipping: g2 resumes.
    overlay.send(ClientMessage::OpenOverlay).await;
    match g2.gn.next_event().await.unwrap() {
        Some(GameEvent::Pause { session }) => assert_eq!(session, s2),
        other => panic!("expected pause, got {other:?}"),
    }
    overlay.send(ClientMessage::CloseOverlay).await;
    match g2.gn.next_event().await.unwrap() {
        Some(GameEvent::Resume { session }) => assert_eq!(session, s2),
        other => panic!("expected resume, got {other:?}"),
    }

    // Ada leaves from the overlay.
    overlay
        .send(ClientMessage::LeaveParty { player_id: ada })
        .await;
    let snap = overlay.wait_for(|p| p.players.is_empty()).await;
    assert!(snap.seats.iter().all(|s| s.occupant.is_empty()));
}

#[tokio::test]
async fn settings_flow_daemon_validates_and_pushes() {
    use gamenight_protocol::{SettingKind, SettingSpec, SettingValue};

    let addr = start_daemon().await;
    let mut overlay = Overlay::connect(&addr).await;
    let mut game = TestGame::connect("lobby", &addr).await;

    game.gn
        .declare_settings(vec![SettingSpec {
            key: "items".into(),
            label: "Items".into(),
            description: None,
            kind: SettingKind::Toggle { default: true },
        }])
        .await
        .unwrap();
    let snap = overlay.wait_for(|p| !p.settings.is_empty()).await;
    assert_eq!(snap.settings[0].values["items"], SettingValue::Toggle(true));

    // Overlay (a person — or an LLM via gamenight-mcp) turns the knob; the
    // game hears about it without a session in flight.
    overlay
        .send(ClientMessage::SetSetting {
            game: Some(GameId::new("lobby")),
            key: "items".into(),
            value: SettingValue::Toggle(false),
        })
        .await;
    match game.gn.next_event().await.unwrap() {
        Some(GameEvent::SettingChanged { key, value }) => {
            assert_eq!(key, "items");
            assert_eq!(value, SettingValue::Toggle(false));
        }
        other => panic!("expected setting_changed, got {other:?}"),
    }
    overlay
        .wait_for(|p| p.settings[0].values["items"] == SettingValue::Toggle(false))
        .await;

    // Role enforcement: games take settings from the party, not vice versa.
    // (Raw socket: the SDK deliberately has no way to send party commands.)
    let (mut ws, _) = tokio_tungstenite::connect_async(format!("ws://{addr}"))
        .await
        .unwrap();
    ws.send(Message::Text(
        ClientMessage::Hello {
            role: Role::Game,
            game: Some(GameId::new("raw-game")),
            token: None,
        }
        .to_json(),
    ))
    .await
    .unwrap();
    ws.send(Message::Text(
        ClientMessage::SetSetting {
            game: None,
            key: "items".into(),
            value: SettingValue::Toggle(true),
        }
        .to_json(),
    ))
    .await
    .unwrap();
    loop {
        match Overlay::recv_raw(&mut ws).await {
            ServerMessage::Error { message } => {
                assert!(message.contains("party commands"), "{message}");
                break;
            }
            _ => continue,
        }
    }
}

#[tokio::test]
async fn duplicate_game_connection_is_rejected() {
    let addr = start_daemon().await;
    let _first = TestGame::connect("dupe", &addr).await;
    let err = GameNight::connect("dupe", Some(&addr)).await;
    assert!(matches!(err, Err(gamenight_sdk::SdkError::Rejected(_))));
}

/// A game with no launch spec (still queued behind other catalogue
/// downloads) gets bumped to the front of the prewarm queue the instant the
/// party tries to warm it — `launch()` shouldn't just silently no-op.
#[tokio::test]
async fn playing_an_uninstalled_game_bumps_the_prewarm_queue() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap().to_string();
    let library = vec![gamenight_protocol::GameMeta {
        id: GameId::new("still-downloading"),
        title: "Still Downloading".into(),
        tagline: None,
        cover: None,
        color: None,
        emoji: None,
        players: None,
        min_players: None,
        max_players: None,
        best_players: None,
        launch: None, // no launch spec: not installed yet
    }];
    let (prewarm, mut priority_rx) = gamenight_installer::prewarm_channel();
    tokio::spawn(gamenight_daemon::run_with_prewarm(
        listener,
        library,
        None,
        Some(prewarm),
    ));

    let mut overlay = Overlay::connect(&addr).await;
    overlay
        .send(ClientMessage::PlayNext {
            game: GameId::new("still-downloading"),
        })
        .await;

    let bumped = tokio::time::timeout(std::time::Duration::from_secs(5), priority_rx.recv())
        .await
        .expect("prewarm should have been notified")
        .expect("channel should still be open");
    assert_eq!(
        bumped,
        gamenight_installer::PrewarmSignal::Prioritize("still-downloading".into())
    );
}

/// A game that quits is never respawned by its own departure.
///
/// This is the crash-loop: losing the active game makes the night pick what
/// to play next, and on a short shelf that pick is the title that just left,
/// so it comes straight back and leaves again. On a desktop title that means
/// windows appearing faster than a person can close them — you cannot even
/// quit it, because quitting is what triggers the relaunch.
///
/// The fake game is a shell script that records the launch token and exits;
/// the test then plays the part of the process, connecting with that token
/// and dropping the socket, which is exactly the connect-then-die shape.
#[tokio::test]
async fn a_game_that_quits_is_not_respawned() {
    let dir = std::env::temp_dir().join(format!("gn-crashloop-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let tokens = dir.join("tokens");
    let _ = std::fs::remove_file(&tokens);
    let quit = tokens.with_extension("quit");
    let _ = std::fs::remove_file(&quit);

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap().to_string();
    let library = vec![gamenight_protocol::GameMeta {
        id: GameId::new("crasher"),
        title: "Crasher".into(),
        tagline: None,
        cover: None,
        color: None,
        emoji: None,
        players: None,
        min_players: None,
        max_players: None,
        best_players: None,
        launch: Some(gamenight_protocol::LaunchSpec {
            command: std::env::current_exe().unwrap().display().to_string(),
            args: vec![
                "--exact".into(),
                "fake_game_process".into(),
                "--nocapture".into(),
            ],
            cwd: None,
            env: [(
                "GAMENIGHT_TEST_TOKEN_FILE".into(),
                tokens.display().to_string(),
            )]
            .into(),
        }),
    }];
    tokio::spawn(gamenight_daemon::run_with_library(listener, library));

    // A seated party is what makes the night want a game warm at all — with
    // nobody playing there is nothing to re-warm and hence no loop to bound.
    let mut overlay = Overlay::connect(&addr).await;
    overlay
        .send(ClientMessage::JoinParty {
            name: "Ada".into(),
            seat: None,
            color: None,
            avatar: None,
            library: Vec::new(),
        })
        .await;
    overlay.wait_for(|p| p.players.len() == 1).await;

    // Play the crashing process: pick up each launch token, connect with it,
    // then drop the socket. Far more attempts than the cap allows, so an
    // unbounded daemon would keep handing out fresh tokens.
    for handled in 0..40 {
        let Some(token) = next_token(&tokens, handled).await else {
            break;
        };
        let (mut ws, _) = tokio_tungstenite::connect_async(format!("ws://{addr}"))
            .await
            .unwrap();
        ws.send(Message::Text(
            ClientMessage::Hello {
                role: Role::Game,
                game: Some(GameId::new("crasher")),
                token: Some(token),
            }
            .to_json(),
        ))
        .await
        .unwrap();
        // Answer Prepare with Ready so the night actually starts us. It's the
        // *active* game disconnecting that drives the night to relaunch — a
        // process that dies while merely warm is not the crash-loop shape.
        for _ in 0..10 {
            match tokio::time::timeout(
                std::time::Duration::from_secs(2),
                Overlay::recv_raw(&mut ws),
            )
            .await
            {
                Ok(ServerMessage::Prepare { session, .. }) => {
                    ws.send(Message::Text(ClientMessage::Ready { session }.to_json()))
                        .await
                        .unwrap();
                }
                Ok(ServerMessage::Start { .. }) => break,
                Ok(_) => continue,
                Err(_) => break,
            }
        }
        drop(ws);
        std::fs::write(&quit, "quit").unwrap();
    }

    // Let any further launch the daemon might attempt actually happen.
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    let launches = std::fs::read_to_string(&tokens)
        .map(|s| s.lines().count())
        .unwrap_or(0);
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(
        launches, 1,
        "the game was launched once and quit; its own departure must not \
         bring it back (got {launches} launches)",
    );
}

/// Wait for launch token number `n` (0-indexed) to show up, or give up.
async fn next_token(path: &std::path::Path, n: usize) -> Option<String> {
    for _ in 0..40 {
        if let Ok(contents) = std::fs::read_to_string(path) {
            if let Some(line) = contents
                .split_inclusive('\n')
                .filter(|line| line.ends_with('\n'))
                .nth(n)
            {
                if !line.trim().is_empty() {
                    return Some(line.trim().to_string());
                }
            }
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    None
}

/// A warming game's loading progress reaches the party, and its "get me back
/// to the lobby" pauses the match — the two things a game may say beyond its
/// own session lifecycle.
#[tokio::test]
async fn a_game_reports_progress_and_can_ask_for_the_overlay() {
    let addr = start_daemon().await;
    let mut overlay = Overlay::connect(&addr).await;
    overlay
        .send(ClientMessage::JoinParty {
            name: "Ada".into(),
            seat: None,
            color: None,
            avatar: None,
            library: Vec::new(),
        })
        .await;
    overlay.wait_for(|p| p.players.len() == 1).await;

    let mut towerfall = TestGame::connect("towerfall", &addr).await;
    overlay
        .send(ClientMessage::SetPlaylist {
            entries: vec![entry("towerfall")],
        })
        .await;

    // Warming: report progress before answering ready, which is exactly when
    // the party is sitting there watching the lobby's screen.
    let session = match towerfall.gn.next_event().await.unwrap() {
        Some(GameEvent::Prepare { session, .. }) => session,
        other => panic!("expected prepare, got {other:?}"),
    };
    towerfall
        .gn
        .progress(session, 42, Some("generating terrain".into()))
        .await
        .unwrap();
    let snap = overlay
        .wait_for(|p| {
            p.warm_session
                .as_ref()
                .is_some_and(|s| s.progress == Some(42))
        })
        .await;
    assert_eq!(
        snap.warm_session.unwrap().progress_label.as_deref(),
        Some("generating terrain"),
    );

    // Now it's ready and playing.
    towerfall.gn.ready(session).await.unwrap();
    towerfall.expect_start(session).await;
    overlay
        .wait_for(|p| p.active_session.as_ref().map(|s| s.phase) == Some(SessionPhase::Running))
        .await;

    // The player asks to get back to the party: the match pauses.
    towerfall.gn.request_overlay().await.unwrap();
    overlay
        .wait_for(|p| p.active_session.as_ref().map(|s| s.phase) == Some(SessionPhase::Paused))
        .await;
}

/// A game speaking the plain transport: a bare TCP socket, one JSON object
/// per line, no WebSocket handshake and no frame codec.
///
/// This is the whole client. It exists in the test suite rather than only in
/// `sdk/c` because the promise it proves — "if your engine can open a socket,
/// you can integrate" — is a daemon guarantee, and should break here first if
/// it ever stops being true.
struct PlainGame {
    lines: tokio::io::Lines<tokio::io::BufReader<tokio::net::tcp::OwnedReadHalf>>,
    write: tokio::net::tcp::OwnedWriteHalf,
}

impl PlainGame {
    async fn connect(game: &str, addr: &str) -> Self {
        use tokio::io::AsyncBufReadExt;
        let (read, write) = TcpStream::connect(addr).await.unwrap().into_split();
        let mut me = Self {
            lines: tokio::io::BufReader::new(read).lines(),
            write,
        };
        me.send(ClientMessage::Hello {
            role: Role::Game,
            game: Some(GameId::new(game)),
            token: None,
        })
        .await;
        match me.recv().await {
            ServerMessage::Welcome {
                protocol_version, ..
            } => assert_eq!(protocol_version, 1),
            other => panic!("expected welcome, got {other:?}"),
        }
        me
    }

    async fn send(&mut self, msg: ClientMessage) {
        use tokio::io::AsyncWriteExt;
        self.write
            .write_all(format!("{}\n", msg.to_json()).as_bytes())
            .await
            .unwrap();
    }

    async fn recv(&mut self) -> ServerMessage {
        let line = self
            .lines
            .next_line()
            .await
            .unwrap()
            .expect("daemon closed");
        serde_json::from_str(&line).unwrap()
    }
}

#[tokio::test]
async fn a_plain_socket_game_plays_a_full_session() {
    let addr = start_daemon().await;
    let mut overlay = Overlay::connect(&addr).await;
    let mut game = PlainGame::connect("plain", &addr).await;

    overlay
        .send(ClientMessage::SetPlaylist {
            entries: vec![entry("plain")],
        })
        .await;

    let session = match game.recv().await {
        ServerMessage::Prepare { session, seats, .. } => {
            assert_eq!(seats.len(), 4, "seats arrive the same on both transports");
            session
        }
        other => panic!("expected prepare, got {other:?}"),
    };
    game.send(ClientMessage::Ready { session }).await;
    match game.recv().await {
        ServerMessage::Start { session: s } => assert_eq!(s, session),
        other => panic!("expected start, got {other:?}"),
    }

    // ...and the party sees it exactly as it would a WebSocket game.
    let party = overlay
        .wait_for(|p| {
            p.active_session
                .as_ref()
                .is_some_and(|s| s.phase == SessionPhase::Running)
        })
        .await;
    assert_eq!(party.connected_games, vec![GameId::new("plain")]);

    // Finishing rolls the night on (nobody is seated, so the vote
    // auto-advances) and our single-entry playlist comes back round to us:
    // dispose, then a brand-new session in the same process.
    game.send(ClientMessage::Finished { session }).await;
    match game.recv().await {
        ServerMessage::Dispose { session: s } => assert_eq!(s, session),
        other => panic!("expected dispose, got {other:?}"),
    }
    match game.recv().await {
        ServerMessage::Prepare { session: s, .. } => assert_ne!(s, session, "ids are never reused"),
        other => panic!("expected a fresh prepare, got {other:?}"),
    }
}

/// Blank lines are keepalive, not protocol errors — a hand-rolled client
/// that ends every write with a stray newline must not be punished for it.
#[tokio::test]
async fn plain_transport_ignores_blank_lines() {
    use tokio::io::AsyncWriteExt;
    let addr = start_daemon().await;
    let mut overlay = Overlay::connect(&addr).await;
    let mut game = PlainGame::connect("chatty", &addr).await;

    game.write.write_all(b"\n\n  \n").await.unwrap();

    // The connection survived them: the party can still reach this game.
    overlay
        .send(ClientMessage::SetPlaylist {
            entries: vec![entry("chatty")],
        })
        .await;
    assert!(
        matches!(game.recv().await, ServerMessage::Prepare { .. }),
        "blank lines should not have killed the connection"
    );
}

// Spawn the same test executable as a tiny portable game process. Unlike a
// shell script this exercises native process launch on Windows too.
#[test]
fn fake_game_process() {
    use std::io::Write;
    let Ok(path) = std::env::var("GAMENIGHT_TEST_TOKEN_FILE") else {
        return;
    };
    let token = std::env::var("GAMENIGHT_TOKEN").unwrap();
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .unwrap();
    file.write_all(format!("{token}\n").as_bytes()).unwrap();
    // Stay alive until the test has connected and dropped the game socket.
    // Exiting before Hello lets another party command reap/relaunch this child
    // and invalidate the token before the simulated game can use it.
    let quit = std::path::Path::new(&path).with_extension("quit");
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while !quit.exists() && std::time::Instant::now() < deadline {
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
}
