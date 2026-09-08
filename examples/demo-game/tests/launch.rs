//! The full launch loop: a daemon with a library entry pointing at the real
//! demo-game binary spawns the process itself, the process detects game-night
//! mode from the environment, connects with its launch token, warms, and the
//! night starts — no human starts any game.

use std::collections::BTreeMap;

use futures_util::{SinkExt, StreamExt};
use tokio::net::TcpListener;
use tokio_tungstenite::tungstenite::Message;

use gamenight_protocol::{
    ClientMessage, GameId, GameMeta, LaunchSpec, PartySnapshot, Role, ServerMessage, SessionPhase,
};

fn spawnable_meta(id: &str) -> GameMeta {
    GameMeta {
        id: GameId::new(id),
        title: id.to_string(),
        tagline: None,
        cover: None,
        color: None,
        emoji: None,
        players: None,
        min_players: None,
        max_players: None,
        best_players: None,
        launch: Some(LaunchSpec {
            // The compiled demo-game binary; identity arrives via GAMENIGHT_*.
            command: env!("CARGO_BIN_EXE_demo-game").to_string(),
            args: vec!["1".into()], // 1-second matches
            cwd: None,
            env: BTreeMap::new(),
        }),
    }
}

/// Drive the daemon as an overlay; wait for snapshots matching `pred`.
struct Overlay {
    ws: tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
    party: Option<PartySnapshot>,
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
        Self { ws, party: None }
    }

    async fn send(&mut self, msg: ClientMessage) {
        self.ws.send(Message::Text(msg.to_json())).await.unwrap();
    }

    async fn wait_for(&mut self, pred: impl Fn(&PartySnapshot) -> bool) -> PartySnapshot {
        if let Some(p) = &self.party {
            if pred(p) {
                return p.clone();
            }
        }
        loop {
            let msg = self.ws.next().await.expect("daemon closed").unwrap();
            let Message::Text(text) = msg else { continue };
            match serde_json::from_str::<ServerMessage>(&text).unwrap() {
                ServerMessage::Welcome { party, .. } | ServerMessage::PartyState { party } => {
                    let hit = pred(&party);
                    self.party = Some(party);
                    if hit {
                        return self.party.clone().unwrap();
                    }
                }
                _ => {}
            }
        }
    }
}

#[tokio::test]
async fn daemon_launches_the_games_itself() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap().to_string();
    tokio::spawn(gamenight_daemon::run_with_library(
        listener,
        vec![spawnable_meta("alpha"), spawnable_meta("beta")],
    ));

    let mut overlay = Overlay::connect(&addr).await;

    // Nothing is running. Play-next should make the daemon spawn "alpha",
    // which connects (token via env), warms, and auto-starts the night.
    overlay
        .send(ClientMessage::PlayNext {
            game: GameId::new("alpha"),
        })
        .await;
    let timeout = tokio::time::timeout(
        std::time::Duration::from_secs(10),
        overlay.wait_for(|p| {
            p.active_session
                .as_ref()
                .is_some_and(|s| s.game == GameId::new("alpha") && s.phase == SessionPhase::Running)
        }),
    );
    let snap = timeout.await.expect("alpha never launched and started");
    assert!(snap.connected_games.contains(&GameId::new("alpha")));

    // Queue "beta": the daemon spawns its process too and it warms behind
    // alpha. No voters are seated, so when alpha's 1s match ends the night
    // auto-rolls into beta.
    overlay
        .send(ClientMessage::PlayNext {
            game: GameId::new("beta"),
        })
        .await;
    let snap = tokio::time::timeout(
        std::time::Duration::from_secs(15),
        overlay.wait_for(|p| {
            p.active_session
                .as_ref()
                .is_some_and(|s| s.game == GameId::new("beta") && s.phase == SessionPhase::Running)
                && p.history.contains(&GameId::new("alpha"))
        }),
    )
    .await
    .expect("beta never took over after alpha finished");
    assert!(snap.connected_games.contains(&GameId::new("beta")));
}

#[tokio::test]
async fn hello_without_the_launch_token_is_rejected() {
    // Spawn a launchable game, then race it with an impostor connection that
    // claims the same game id without the token.
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap().to_string();
    tokio::spawn(gamenight_daemon::run_with_library(
        listener,
        vec![spawnable_meta("guarded")],
    ));

    let mut overlay = Overlay::connect(&addr).await;
    overlay
        .send(ClientMessage::PlayNext {
            game: GameId::new("guarded"),
        })
        .await;

    // While the launch is pending (or even after), a token-less claim on the
    // id must fail: either "bad or missing launch token" (pending) or
    // "already connected" (the real process won the race).
    let (mut ws, _) = tokio_tungstenite::connect_async(format!("ws://{addr}"))
        .await
        .unwrap();
    ws.send(Message::Text(
        ClientMessage::Hello {
            role: Role::Game,
            game: Some(GameId::new("guarded")),
            token: None,
        }
        .to_json(),
    ))
    .await
    .unwrap();
    let verdict = tokio::time::timeout(std::time::Duration::from_secs(5), async {
        loop {
            match ws.next().await {
                Some(Ok(Message::Text(text))) => {
                    match serde_json::from_str::<ServerMessage>(&text).unwrap() {
                        ServerMessage::Error { message } => break message,
                        ServerMessage::Welcome { .. } => break "welcomed!".into(),
                        _ => continue,
                    }
                }
                Some(Ok(_)) => continue,
                _ => break "closed".into(),
            }
        }
    })
    .await
    .expect("no verdict from daemon");
    assert!(
        verdict.contains("token") || verdict.contains("already connected"),
        "impostor was let in: {verdict}"
    );

    // The real, token-holding process still gets in and the night starts.
    tokio::time::timeout(
        std::time::Duration::from_secs(10),
        overlay.wait_for(|p| {
            p.active_session
                .as_ref()
                .is_some_and(|s| s.phase == SessionPhase::Running)
        }),
    )
    .await
    .expect("the launched process never started the night");
}
