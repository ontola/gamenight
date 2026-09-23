use futures_util::{SinkExt, StreamExt};
use gamenight_sdk::{GameEvent, GameNight};
use tokio_tungstenite::tungstenite::Message;

#[tokio::test]
async fn rust_game_receives_host_frames_and_disconnects() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut ws = tokio_tungstenite::accept_async(stream).await.unwrap();
        let hello = ws.next().await.unwrap().unwrap().into_text().unwrap();
        assert!(hello.contains("\"game\":\"sdk-frame-test\""));
        ws.send(Message::Text(
            serde_json::json!({
                "type": "welcome", "protocol_version": 1,
                "party": {"players": [], "seats": [], "playlist": {"entries": []},
                          "history": [], "vote": {"positions": []}}
            })
            .to_string(),
        ))
        .await
        .unwrap();
        ws.send(Message::Text(serde_json::json!({
            "type": "controller_frame",
            "controllers": [{"controller": "ordinal:7", "axes": [16384, 0, 0, 0, 0, 0], "buttons": 1}]
        }).to_string())).await.unwrap();
        ws.send(Message::Text(
            serde_json::json!({
                "type": "controller_frame", "controllers": []
            })
            .to_string(),
        ))
        .await
        .unwrap();
    });

    let mut game = GameNight::connect("sdk-frame-test", Some(&addr.to_string()))
        .await
        .unwrap();
    match game.next_event().await.unwrap().unwrap() {
        GameEvent::ControllerFrame { controllers } => {
            assert_eq!(controllers.len(), 1);
            assert_eq!(controllers[0].controller, "ordinal:7");
            assert_eq!(controllers[0].axes[0], 16384);
            assert_eq!(controllers[0].buttons, 1);
        }
        other => panic!("expected controller frame, got {other:?}"),
    }
    assert!(matches!(game.next_event().await.unwrap().unwrap(),
        GameEvent::ControllerFrame { controllers } if controllers.is_empty()));
    server.await.unwrap();
}
