//! The session assistant for games that serve MCP tools while they run (Warp
//! live control, `GameCommands::mcp`). The tools stay the game's own: this
//! host lists and calls them, and the cloud only answers with the model's
//! next step, for the player whose request this is. The game's token never
//! leaves this computer.
use super::Bridge;
use serde::Deserialize;
use serde_json::{json, Value};
use std::time::Duration;

/// Model turns for one request; each may call several tools.
const MAX_STEPS: usize = 10;
/// Bytes of tool output per call that go to the model (images excepted).
const MAX_TEXT: usize = 12_000;
/// What the model sees of the game's own guide.
const MAX_GUIDE: usize = 6_000;

#[derive(Deserialize)]
struct TokenFile {
    url: String,
    token: String,
}

/// Talks MCP (JSON-RPC over HTTP POST) to the game's local endpoint.
struct Game {
    http: reqwest::Client,
    url: String,
    token: String,
    next: u64,
}

impl Game {
    fn open(path: &str) -> Result<Self, String> {
        let file: TokenFile = std::fs::read(path)
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .ok_or("The game's live control is not running")?;
        let url = reqwest::Url::parse(&file.url).map_err(|_| "Bad live-control address")?;
        // Only the game on this computer; never send its token elsewhere.
        if url.scheme() != "http"
            || !matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"))
        {
            return Err("Live control must be on this computer".into());
        }
        Ok(Self {
            http: reqwest::Client::builder()
                .timeout(Duration::from_secs(40))
                .redirect(reqwest::redirect::Policy::none())
                .no_proxy()
                .build()
                .map_err(|_| "No HTTP client")?,
            url: file.url,
            token: file.token,
            next: 0,
        })
    }

    async fn rpc(&mut self, method: &str, params: Value) -> Result<Value, String> {
        self.next += 1;
        let reply: Value = self
            .http
            .post(&self.url)
            .bearer_auth(&self.token)
            .json(&json!({"jsonrpc":"2.0","id":self.next,"method":method,"params":params}))
            .send()
            .await
            .map_err(|_| "The game's live control did not answer")?
            .json()
            .await
            .map_err(|_| "The game's live control answered garbage")?;
        if let Some(message) = reply["error"]["message"].as_str() {
            return Err(message.to_string());
        }
        Ok(reply["result"].clone())
    }
}

/// The model's view of an MCP tool.
fn tool(t: &Value) -> Option<Value> {
    Some(json!({
        "name": t["name"].as_str()?,
        "description": cut(t["description"].as_str().unwrap_or(""), 1500),
        "input_schema": t.get("inputSchema").cloned().unwrap_or(json!({"type":"object"})),
    }))
}

/// An MCP tool result as the content of the model's `tool_result`.
fn result_content(result: &Value) -> Vec<Value> {
    let mut out = Vec::new();
    for part in result["content"].as_array().into_iter().flatten() {
        match part["type"].as_str() {
            Some("text") => out.push(
                json!({"type":"text","text":cut(part["text"].as_str().unwrap_or(""), MAX_TEXT)}),
            ),
            Some("image") => out.push(json!({"type":"image","source":{"type":"base64",
                "media_type":part["mimeType"].as_str().unwrap_or("image/png"),
                "data":part["data"].as_str().unwrap_or("")}})),
            _ => {}
        }
    }
    if out.is_empty() {
        out.push(json!({"type":"text","text":"(no output)"}));
    }
    out
}

/// Only the newest screenshot stays: older ones become a note, so a request
/// stays small however often the model looks.
fn forget_old_images(messages: &mut [Value]) {
    for message in messages.iter_mut() {
        for block in message["content"].as_array_mut().into_iter().flatten() {
            for part in block["content"].as_array_mut().into_iter().flatten() {
                if part["type"] == "image" {
                    *part = json!({"type":"text","text":"(an earlier screenshot)"});
                }
            }
        }
    }
}

fn cut(text: &str, max: usize) -> String {
    if text.len() <= max {
        return text.to_string();
    }
    format!("{}…", &text[..text.floor_char_boundary(max)])
}

/// Carries out `text` for the request `id` with the game's tools, and returns
/// what the model says it did.
pub(crate) async fn run(bridge: &Bridge, id: &str, path: &str) -> Result<String, String> {
    let mut game = Game::open(path)?;
    let hello = game
        .rpc(
            "initialize",
            json!({"protocolVersion":"2025-06-18","capabilities":{},
                "clientInfo":{"name":"gamenight-assistant","version":env!("CARGO_PKG_VERSION")}}),
        )
        .await?;
    let guide = cut(hello["instructions"].as_str().unwrap_or(""), MAX_GUIDE);
    let tools: Vec<Value> = game.rpc("tools/list", json!({})).await?["tools"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(tool)
        .take(64)
        .collect();
    let mut messages: Vec<Value> = Vec::new();
    let mut said = String::new();
    for _ in 0..MAX_STEPS {
        let step = bridge
            .live_step(json!({"request_id":id,"guide":guide,"tools":tools,"messages":messages}))
            .await?;
        let content = step["content"].as_array().cloned().unwrap_or_default();
        said = content
            .iter()
            .filter_map(|b| (b["type"] == "text").then(|| b["text"].as_str()).flatten())
            .collect::<Vec<_>>()
            .join("\n");
        let calls: Vec<&Value> = content.iter().filter(|b| b["type"] == "tool_use").collect();
        if calls.is_empty() {
            return if said.trim().is_empty() {
                Err("The assistant gave no answer".into())
            } else {
                Ok(cut(said.trim(), 900))
            };
        }
        let mut results = Vec::new();
        for call in calls {
            let name = call["name"].as_str().unwrap_or("");
            let (content, error) = match game
                .rpc(
                    "tools/call",
                    json!({"name":name,"arguments":call["input"].clone()}),
                )
                .await
            {
                Ok(r) => (result_content(&r), r["isError"] == true),
                Err(e) => (vec![json!({"type":"text","text":e})], true),
            };
            results.push(json!({"type":"tool_result","tool_use_id":call["id"],
                "content":content,"is_error":error}));
        }
        forget_old_images(&mut messages);
        messages.push(json!({"role":"assistant","content":content}));
        messages.push(json!({"role":"user","content":results}));
    }
    Err(if said.trim().is_empty() {
        "The assistant needed too many steps and stopped".into()
    } else {
        cut(said.trim(), 900)
    })
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use axum::{extract::State, routing::post, Json, Router};
    use std::sync::{Arc, Mutex};

    /// A cloud that asks for `set_knob speed 2` once and then says it is done,
    /// and a game that serves that tool. Returns the bridge, the token file
    /// and every tool call the game got.
    pub(crate) async fn fake_cloud_and_game() -> (Bridge, String, Arc<Mutex<Vec<Value>>>) {
        let calls = Arc::new(Mutex::new(Vec::new()));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        async fn mcp(
            State(calls): State<Arc<Mutex<Vec<Value>>>>,
            headers: axum::http::HeaderMap,
            Json(m): Json<Value>,
        ) -> Json<Value> {
            assert_eq!(headers["authorization"], "Bearer secret");
            let result = match m["method"].as_str().unwrap() {
                "initialize" => json!({"instructions":"Call knobs first."}),
                "tools/list" => json!({"tools":[{"name":"set_knob","description":"Set one knob",
                    "inputSchema":{"type":"object","properties":{"name":{"type":"string"}}}}]}),
                "tools/call" => {
                    calls.lock().unwrap().push(m["params"].clone());
                    json!({"content":[{"type":"text","text":"speed = 2"}],"isError":false})
                }
                _ => unreachable!(),
            };
            Json(json!({"jsonrpc":"2.0","id":m["id"],"result":result}))
        }
        async fn step(headers: axum::http::HeaderMap, Json(body): Json<Value>) -> Json<Value> {
            assert_eq!(headers["authorization"], "Bearer host");
            assert_eq!(body["guide"], "Call knobs first.");
            assert_eq!(body["tools"][0]["input_schema"]["type"], "object");
            Json(match body["messages"].as_array().unwrap().len() {
                0 => json!({"content":[{"type":"tool_use","id":"t1","name":"set_knob",
                    "input":{"name":"speed","value":"2"}}]}),
                _ => {
                    assert_eq!(
                        body["messages"][1]["content"][0]["content"][0]["text"],
                        "speed = 2"
                    );
                    json!({"content":[{"type":"text","text":"Ik heb de snelheid verdubbeld."}]})
                }
            })
        }
        let app = Router::new()
            .route("/mcp", post(mcp))
            .with_state(calls.clone())
            .route("/v1/lobbies/assistant", post(step));
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let dir = std::env::temp_dir().join(format!(
            "gn-live-run-{}-{}",
            std::process::id(),
            addr.port()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("game.json");
        std::fs::write(
            &file,
            json!({"url":format!("http://{addr}/mcp"),"token":"secret"}).to_string(),
        )
        .unwrap();
        let bridge = Bridge {
            origin: format!("http://{addr}"),
            http: reqwest::Client::builder().no_proxy().build().unwrap(),
            session: Arc::new(Mutex::new(Some("host".into()))),
            seats: Arc::default(),
            waiting: Arc::default(),
            pairing: Arc::default(),
            pairing_request: Arc::default(),
            refresh: Arc::default(),
        };
        (bridge, file.to_string_lossy().into_owned(), calls)
    }

    #[tokio::test]
    async fn requests_run_the_games_own_tools_with_steps_from_the_cloud() {
        let (bridge, file, calls) = fake_cloud_and_game().await;
        assert_eq!(
            run(&bridge, "ask-1", &file).await.unwrap(),
            "Ik heb de snelheid verdubbeld."
        );
        assert_eq!(
            calls.lock().unwrap()[0],
            json!({"name":"set_knob","arguments":{"name":"speed","value":"2"}})
        );
    }

    #[test]
    fn tool_results_keep_text_and_images_and_only_the_newest_image_stays() {
        let r = json!({"content":[{"type":"text","text":"ok"},{"type":"image","mimeType":"image/png","data":"QUJD"}]});
        let content = result_content(&r);
        assert_eq!(content[0]["text"], "ok");
        assert_eq!(content[1]["source"]["data"], "QUJD");
        let mut messages = vec![
            json!({"role":"user","content":[{"type":"tool_result","tool_use_id":"a","content":content}]}),
        ];
        forget_old_images(&mut messages);
        assert_eq!(messages[0]["content"][0]["content"][1]["type"], "text");
        assert_eq!(cut("ééé", 3), "é…");
    }

    #[test]
    fn token_files_may_only_point_at_this_computer() {
        let dir = std::env::temp_dir().join(format!("gn-live-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("game.json");
        std::fs::write(&file, r#"{"url":"http://example.com/mcp","token":"t"}"#).unwrap();
        assert!(Game::open(file.to_str().unwrap()).is_err());
        std::fs::write(
            &file,
            r#"{"url":"http://127.0.0.1:7878/mcp","token":"t","pid":1}"#,
        )
        .unwrap();
        assert!(Game::open(file.to_str().unwrap()).is_ok());
        assert!(Game::open(dir.join("missing.json").to_str().unwrap()).is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
