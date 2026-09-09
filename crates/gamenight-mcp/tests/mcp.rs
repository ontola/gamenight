//! End-to-end: a real daemon, a real game (via the SDK) declaring settings,
//! and the MCP layer driving both — the "hey GameNight, disable items" path.

use serde_json::{json, Value};
use tokio::net::TcpListener;

use gamenight_mcp::{handle_message, DaemonClient};
use gamenight_protocol::{SettingKind, SettingSpec, SettingValue};
use gamenight_sdk::{GameEvent, GameNight};

async fn start_daemon() -> String {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap().to_string();
    tokio::spawn(gamenight_daemon::run_with_library(listener, Vec::new()));
    addr
}

/// A connected game that declared the classic party knobs.
async fn game_with_settings(addr: &str) -> GameNight {
    let mut gn = GameNight::connect("lobby", Some(addr)).await.unwrap();
    gn.declare_settings(vec![
        SettingSpec {
            key: "items".into(),
            label: "Items".into(),
            description: Some("Whether power-ups spawn.".into()),
            kind: SettingKind::Toggle { default: true },
        },
        SettingSpec {
            key: "stock".into(),
            label: "Stock".into(),
            description: None,
            kind: SettingKind::Number {
                default: 3,
                min: 1,
                max: 99,
            },
        },
    ])
    .await
    .unwrap();
    gn
}

/// The game's `declare_settings` and our hello ride different connections;
/// wait until the declaration shows up in the snapshot before asserting.
async fn wait_for_settings(client: &DaemonClient) {
    for _ in 0..200 {
        if !client.party().settings.is_empty() {
            return;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    panic!("declared settings never appeared in the party snapshot");
}

async fn call(client: &DaemonClient, id: u64, name: &str, args: Value) -> (String, bool) {
    let response = handle_message(
        client,
        &json!({
            "jsonrpc": "2.0", "id": id, "method": "tools/call",
            "params": { "name": name, "arguments": args }
        }),
    )
    .await
    .expect("requests get responses");
    let text = response["result"]["content"][0]["text"]
        .as_str()
        .unwrap()
        .to_string();
    let is_error = response["result"]["isError"].as_bool().unwrap_or(false);
    (text, is_error)
}

#[tokio::test]
async fn disable_items_end_to_end() {
    let addr = start_daemon().await;
    let mut game = game_with_settings(&addr).await;
    let client = DaemonClient::connect(&addr).await.unwrap();
    wait_for_settings(&client).await;

    // The handshake and the tool list.
    let init = handle_message(
        &client,
        &json!({ "jsonrpc": "2.0", "id": 1, "method": "initialize",
                 "params": { "protocolVersion": "2025-06-18" } }),
    )
    .await
    .unwrap();
    assert_eq!(init["result"]["protocolVersion"], "2025-06-18");
    assert_eq!(init["result"]["serverInfo"]["name"], "gamenight");
    // Notifications get no response.
    assert!(handle_message(
        &client,
        &json!({ "jsonrpc": "2.0", "method": "notifications/initialized" })
    )
    .await
    .is_none());
    let tools = handle_message(
        &client,
        &json!({ "jsonrpc": "2.0", "id": 2, "method": "tools/list" }),
    )
    .await
    .unwrap();
    let names: Vec<&str> = tools["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap())
        .collect();
    assert!(names.contains(&"set_setting") && names.contains(&"party_status"));

    // The model grounds itself: what does this game expose?
    let (text, is_error) = call(&client, 3, "list_settings", json!({ "game": "lobby" })).await;
    assert!(!is_error);
    assert!(
        text.contains("\"items\"") && text.contains("\"current\": true"),
        "{text}"
    );

    // "Hey GameNight, let's disable items."
    let (text, is_error) = call(
        &client,
        4,
        "set_setting",
        json!({ "game": "lobby", "key": "items", "value": false }),
    )
    .await;
    assert!(!is_error, "{text}");
    assert!(text.contains("Done"), "{text}");

    // The game heard about it, live.
    match game.next_event().await.unwrap() {
        Some(GameEvent::SettingChanged { key, value }) => {
            assert_eq!(key, "items");
            assert_eq!(value, SettingValue::Toggle(false));
        }
        other => panic!("expected setting_changed, got {other:?}"),
    }

    // A voice-transcript value ("5" for a number) is coerced before sending.
    let (text, is_error) = call(
        &client,
        5,
        "set_setting",
        json!({ "game": "lobby", "key": "stock", "value": "5" }),
    )
    .await;
    assert!(!is_error, "{text}");
    match game.next_event().await.unwrap() {
        Some(GameEvent::SettingChanged { key, value }) => {
            assert_eq!(key, "stock");
            assert_eq!(value, SettingValue::Number(5));
        }
        other => panic!("expected setting_changed, got {other:?}"),
    }
}

#[tokio::test]
async fn rejections_reach_the_model_verbatim() {
    let addr = start_daemon().await;
    let _game = game_with_settings(&addr).await;
    let client = DaemonClient::connect(&addr).await.unwrap();
    wait_for_settings(&client).await;

    // Unknown key: the error lists what exists, so the model self-corrects.
    let (text, is_error) = call(
        &client,
        1,
        "set_setting",
        json!({ "game": "lobby", "key": "itemz", "value": false }),
    )
    .await;
    assert!(is_error);
    assert!(text.contains("available: items, stock"), "{text}");

    // Out-of-range: the error states the legal range.
    let (text, is_error) = call(
        &client,
        2,
        "set_setting",
        json!({ "game": "lobby", "key": "stock", "value": 500 }),
    )
    .await;
    assert!(is_error);
    assert!(text.contains("between 1 and 99"), "{text}");

    // No active game and no explicit id: told what to do instead.
    let (text, is_error) = call(&client, 3, "list_settings", json!({})).await;
    assert!(is_error);
    assert!(text.contains("pass a 'game' id"), "{text}");
}

#[tokio::test]
async fn party_status_reads_the_room() {
    let addr = start_daemon().await;
    let _game = game_with_settings(&addr).await;
    let client = DaemonClient::connect(&addr).await.unwrap();

    let (text, is_error) = call(&client, 1, "party_status", json!({})).await;
    assert!(!is_error);
    let status: Value = serde_json::from_str(&text).expect("status is JSON");
    assert!(status["now_playing"].is_null());
    assert_eq!(status["players"].as_array().unwrap().len(), 4); // 4 empty seats
}
