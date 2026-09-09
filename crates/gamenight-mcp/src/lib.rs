//! GameNight's MCP server: "hey GameNight, disable items."
//!
//! Speaks the [Model Context Protocol](https://modelcontextprotocol.io) over
//! stdio (newline-delimited JSON-RPC 2.0) on one side, and the GameNight wire
//! protocol (as an overlay-role client) on the other. Point Claude — or any
//! voice assistant that can call MCP tools — at the binary and the party
//! gains a member that can read the room and turn the knobs:
//!
//! ```sh
//! claude mcp add gamenight -- gamenight-mcp
//! ```
//!
//! The tools mirror what a person can do from the overlay, nothing more: the
//! daemon still validates every write, so an LLM can never put a game into a
//! state a human couldn't. Rejections come back verbatim ("'towerfall' has
//! no setting 'itemz'; available: items, stock…") — exactly the feedback a
//! model needs to correct itself.

use std::sync::Arc;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio::sync::{mpsc, watch, Mutex};
use tokio_tungstenite::tungstenite::Message;

use gamenight_protocol::{
    ClientMessage, GameId, GameSettings, PartySnapshot, Role, ServerMessage, SettingKind,
    SettingValue, DEFAULT_ADDR, ENV_ADDR,
};

/// How long a command may take to show up in the party snapshot before we
/// report it as "sent, but unconfirmed".
const CONFIRM_TIMEOUT: Duration = Duration::from_secs(3);

/// The daemon address to use: `GAMENIGHT_ADDR` or the standard local one.
pub fn daemon_addr() -> String {
    std::env::var(ENV_ADDR).unwrap_or_else(|_| DEFAULT_ADDR.to_string())
}

// ---------------------------------------------------------------------------
// Daemon client
// ---------------------------------------------------------------------------

/// An overlay-role connection to the daemon, kept current in the background.
pub struct DaemonClient {
    to_daemon: mpsc::UnboundedSender<Message>,
    snapshot: watch::Receiver<PartySnapshot>,
    /// Daemon `error` replies. The protocol has no correlation ids, but MCP
    /// tool calls run one at a time (guarded by `in_flight`), so an error
    /// arriving while a command waits belongs to that command.
    errors: Mutex<mpsc::UnboundedReceiver<String>>,
    in_flight: Mutex<()>,
}

impl DaemonClient {
    /// Connect and say hello as an overlay. Fails fast when no daemon is up —
    /// the MCP client shows that message, which beats silent tool timeouts.
    pub async fn connect(addr: &str) -> Result<Arc<Self>, String> {
        let (ws, _) = tokio_tungstenite::connect_async(format!("ws://{addr}"))
            .await
            .map_err(|e| format!("cannot reach the GameNight daemon at {addr}: {e}"))?;
        let (mut sink, mut stream) = ws.split();
        sink.send(Message::Text(
            ClientMessage::Hello {
                role: Role::Overlay,
                game: None,
                token: None,
            }
            .to_json(),
        ))
        .await
        .map_err(|e| e.to_string())?;

        // The welcome carries the first snapshot.
        let party = loop {
            match stream.next().await {
                Some(Ok(Message::Text(text))) => {
                    match serde_json::from_str::<ServerMessage>(&text) {
                        Ok(ServerMessage::Welcome { party, .. }) => break party,
                        Ok(ServerMessage::Error { message }) => return Err(message),
                        _ => continue,
                    }
                }
                Some(Ok(_)) => continue,
                Some(Err(e)) => return Err(e.to_string()),
                None => return Err("daemon closed the connection during hello".into()),
            }
        };

        let (snap_tx, snap_rx) = watch::channel(party);
        let (err_tx, err_rx) = mpsc::unbounded_channel();
        let (out_tx, mut out_rx) = mpsc::unbounded_channel::<Message>();

        tokio::spawn(async move {
            while let Some(msg) = out_rx.recv().await {
                if sink.send(msg).await.is_err() {
                    break;
                }
            }
        });
        tokio::spawn(async move {
            while let Some(Ok(msg)) = stream.next().await {
                let Message::Text(text) = msg else { continue };
                match serde_json::from_str::<ServerMessage>(&text) {
                    Ok(ServerMessage::PartyState { party }) => {
                        let _ = snap_tx.send(party);
                    }
                    Ok(ServerMessage::Error { message }) => {
                        let _ = err_tx.send(message);
                    }
                    _ => {}
                }
            }
        });

        Ok(Arc::new(Self {
            to_daemon: out_tx,
            snapshot: snap_rx,
            errors: Mutex::new(err_rx),
            in_flight: Mutex::new(()),
        }))
    }

    pub fn party(&self) -> PartySnapshot {
        self.snapshot.borrow().clone()
    }

    /// Send `msg` and wait until the party snapshot satisfies `confirmed` or
    /// the daemon rejects it. `Ok(None)` = sent but unconfirmed in time (the
    /// command may still land later, e.g. a skip waiting on a warm-up).
    async fn command(
        &self,
        msg: ClientMessage,
        confirmed: impl Fn(&PartySnapshot) -> bool,
    ) -> Result<Option<PartySnapshot>, String> {
        let _guard = self.in_flight.lock().await;
        let mut errors = self.errors.lock().await;
        while errors.try_recv().is_ok() {} // drop stale errors
        let mut snapshots = self.snapshot.clone();
        snapshots.mark_changed(); // re-check the current snapshot first
        self.to_daemon
            .send(Message::Text(msg.to_json()))
            .map_err(|_| "lost the connection to the daemon".to_string())?;
        let deadline = tokio::time::Instant::now() + CONFIRM_TIMEOUT;
        loop {
            tokio::select! {
                _ = tokio::time::sleep_until(deadline) => return Ok(None),
                err = errors.recv() => {
                    return Err(err.unwrap_or_else(|| "connection to the daemon lost".into()));
                }
                changed = snapshots.changed() => {
                    if changed.is_err() {
                        return Err("connection to the daemon lost".into());
                    }
                    let snap = snapshots.borrow_and_update().clone();
                    if confirmed(&snap) {
                        return Ok(Some(snap));
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// The tools
// ---------------------------------------------------------------------------

/// Tool definitions in MCP `tools/list` shape.
pub fn tool_definitions() -> Value {
    let game_arg = json!({
        "type": "string",
        "description": "Game id (e.g. 'towerfall'). Defaults to the game being played right now."
    });
    json!([
        {
            "name": "party_status",
            "description": "What's happening at the party right now: who's here and in which seat, \
                what's playing, what's warming up next, the playlist, any open vote, and the \
                match settings of the active game. Call this first to ground yourself.",
            "inputSchema": { "type": "object", "properties": {} }
        },
        {
            "name": "list_settings",
            "description": "The match settings a game exposes (key, label, description, allowed \
                values) and their current values. Use it to map a wish like 'disable items' onto \
                a setting key before calling set_setting.",
            "inputSchema": { "type": "object", "properties": { "game": game_arg } }
        },
        {
            "name": "set_setting",
            "description": "Change one match setting, e.g. {key: 'items', value: false} for \
                'let's disable items'. The change applies live (or from the next match — the \
                game decides what's sensible). The daemon validates the value and its refusals \
                spell out what is allowed.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "key": { "type": "string", "description": "The setting's key, from list_settings." },
                    "value": {
                        "type": ["boolean", "integer", "string"],
                        "description": "New value: true/false for toggles, an integer for numbers, an option string for choices."
                    },
                    "game": game_arg
                },
                "required": ["key", "value"]
            }
        },
        {
            "name": "play_next",
            "description": "Make a game the next one up — it starts warming immediately and the \
                party can switch the moment it's ready. Use game ids from party_status's library.",
            "inputSchema": {
                "type": "object",
                "properties": { "game": { "type": "string", "description": "Game id from the library." } },
                "required": ["game"]
            }
        },
        {
            "name": "skip",
            "description": "Skip to the next game right now, no vote. Ends the current match.",
            "inputSchema": { "type": "object", "properties": {} }
        },
        {
            "name": "pause",
            "description": "Pause the game being played.",
            "inputSchema": { "type": "object", "properties": {} }
        },
        {
            "name": "resume",
            "description": "Resume a paused game.",
            "inputSchema": { "type": "object", "properties": {} }
        }
    ])
}

/// Execute one tool call. `Err` becomes an MCP `isError` result — the text is
/// read by the model and acted on, so failures explain themselves.
pub async fn call_tool(client: &DaemonClient, name: &str, args: &Value) -> Result<String, String> {
    match name {
        "party_status" => Ok(render_status(&client.party())),
        "list_settings" => {
            let party = client.party();
            let game = resolve_game(&party, args)?;
            match party.settings.iter().find(|s| s.game == game) {
                Some(s) => Ok(render_settings(s)),
                None => Ok(format!(
                    "'{game}' exposes no match settings (it never declared any)."
                )),
            }
        }
        "set_setting" => {
            let party = client.party();
            let game = resolve_game(&party, args)?;
            let key = require_str(args, "key")?.to_string();
            let raw = args.get("value").ok_or("missing 'value'")?;
            let value = coerce_value(&party, &game, &key, raw)?;
            let (g, k, v) = (game.clone(), key.clone(), value.clone());
            let confirmed = client
                .command(
                    ClientMessage::SetSetting {
                        game: Some(game),
                        key,
                        value,
                    },
                    move |p| {
                        p.settings
                            .iter()
                            .find(|s| s.game == g)
                            .and_then(|s| s.values.get(&k))
                            == Some(&v)
                    },
                )
                .await?;
            Ok(match confirmed {
                Some(_) => "Done — the setting is changed and the game has been told.".into(),
                None => "Sent, but the daemon never confirmed it. Check party_status.".into(),
            })
        }
        "play_next" => {
            let game = GameId::new(require_str(args, "game")?);
            let g = game.clone();
            let confirmed = client
                .command(ClientMessage::PlayNext { game: game.clone() }, move |p| {
                    p.warm_session.as_ref().is_some_and(|s| s.game == g)
                        || p.active_session.as_ref().is_some_and(|s| s.game == g)
                })
                .await?;
            Ok(match confirmed {
                Some(_) => format!("'{game}' is up next and warming (or already live)."),
                None => format!(
                    "'{game}' is queued next, but no process for it is warming yet — \
                     it starts loading as soon as its process connects."
                ),
            })
        }
        "skip" => {
            let before = client.party().active_session.map(|s| s.id);
            let confirmed = client
                .command(ClientMessage::Next, move |p| {
                    p.active_session.is_some() && p.active_session.as_ref().map(|s| s.id) != before
                })
                .await?;
            Ok(match confirmed {
                Some(p) => format!(
                    "Skipped — now playing '{}'.",
                    p.active_session.expect("confirmed").game
                ),
                None => {
                    "Skip requested; the next game starts the moment it finishes warming.".into()
                }
            })
        }
        "pause" => {
            client
                .command(ClientMessage::Pause, |p| {
                    p.active_session
                        .as_ref()
                        .is_some_and(|s| s.phase == gamenight_protocol::SessionPhase::Paused)
                })
                .await?;
            Ok("Paused.".into())
        }
        "resume" => {
            client
                .command(ClientMessage::Resume, |p| {
                    p.active_session
                        .as_ref()
                        .is_some_and(|s| s.phase == gamenight_protocol::SessionPhase::Running)
                })
                .await?;
            Ok("Resumed.".into())
        }
        other => Err(format!("unknown tool '{other}'")),
    }
}

/// Which game a tool call is about: the `game` argument, or whatever is
/// active right now.
fn resolve_game(party: &PartySnapshot, args: &Value) -> Result<GameId, String> {
    if let Some(g) = args.get("game").and_then(Value::as_str) {
        return Ok(GameId::new(g));
    }
    party
        .active_session
        .as_ref()
        .map(|s| s.game.clone())
        .ok_or_else(|| "nothing is playing right now — pass a 'game' id explicitly".into())
}

fn require_str<'a>(args: &'a Value, key: &str) -> Result<&'a str, String> {
    args.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("missing '{key}'"))
}

/// Map a JSON argument onto a typed value, using the declared kind to be
/// forgiving about representation ("30" for a number, "true" for a toggle —
/// the kind of thing a voice transcript produces).
fn coerce_value(
    party: &PartySnapshot,
    game: &GameId,
    key: &str,
    raw: &Value,
) -> Result<SettingValue, String> {
    let kind = party
        .settings
        .iter()
        .find(|s| &s.game == game)
        .and_then(|s| s.specs.iter().find(|spec| spec.key == key))
        .map(|spec| &spec.kind);
    Ok(match (kind, raw) {
        (Some(SettingKind::Toggle { .. }), Value::String(s)) if s == "true" || s == "false" => {
            SettingValue::Toggle(s == "true")
        }
        (Some(SettingKind::Number { .. }), Value::String(s)) if s.parse::<i64>().is_ok() => {
            SettingValue::Number(s.parse().expect("checked"))
        }
        // Everything else passes through as-is; the daemon's validation
        // produces the message that explains what would have been legal.
        _ => serde_json::from_value(raw.clone())
            .map_err(|_| "value must be a boolean, integer or string".to_string())?,
    })
}

fn render_status(p: &PartySnapshot) -> String {
    let mut out = serde_json::Map::new();
    out.insert(
        "players".into(),
        p.seats
            .iter()
            .map(|seat| {
                let who = match seat.occupant.player_id() {
                    Some(id) => p
                        .players
                        .iter()
                        .find(|pl| pl.id == id)
                        .map(|pl| pl.name.clone())
                        .unwrap_or_else(|| "?".into()),
                    None => match seat.occupant {
                        gamenight_protocol::SeatOccupant::Ai => "(bot)".into(),
                        _ => "(empty)".into(),
                    },
                };
                json!({ "seat": seat.index, "who": who })
            })
            .collect(),
    );
    out.insert(
        "now_playing".into(),
        match &p.active_session {
            Some(s) => json!({ "game": s.game, "phase": s.phase }),
            None => Value::Null,
        },
    );
    out.insert(
        "up_next".into(),
        match &p.warm_session {
            Some(s) => json!({ "game": s.game, "phase": s.phase }),
            None => Value::Null,
        },
    );
    out.insert(
        "playlist".into(),
        json!(p
            .playlist
            .entries
            .iter()
            .map(|e| e.game.0.clone())
            .collect::<Vec<_>>()),
    );
    out.insert(
        "library".into(),
        json!(p
            .library
            .iter()
            .map(|m| json!({
                "id": m.id,
                "title": m.title,
                "connected": p.connected_games.contains(&m.id)
            }))
            .collect::<Vec<_>>()),
    );
    if let Some(active) = &p.active_session {
        if let Some(s) = p.settings.iter().find(|s| s.game == active.game) {
            out.insert(
                "active_game_settings".into(),
                serde_json::to_value(&s.values).expect("serializes"),
            );
        }
    }
    if !p.vote.positions.is_empty() {
        out.insert(
            "vote_in_progress".into(),
            serde_json::to_value(&p.vote).expect("serializes"),
        );
    }
    serde_json::to_string_pretty(&Value::Object(out)).expect("serializes")
}

fn render_settings(s: &GameSettings) -> String {
    let specs: Vec<Value> = s
        .specs
        .iter()
        .map(|spec| {
            let mut v = serde_json::to_value(spec).expect("serializes");
            v["current"] = serde_json::to_value(s.values.get(&spec.key)).expect("serializes");
            v
        })
        .collect();
    serde_json::to_string_pretty(&json!({ "game": s.game, "settings": specs })).expect("serializes")
}

// ---------------------------------------------------------------------------
// MCP over JSON-RPC
// ---------------------------------------------------------------------------

/// Handle one incoming JSON-RPC message. `None` = no response (notification).
pub async fn handle_message(client: &DaemonClient, msg: &Value) -> Option<Value> {
    let method = msg.get("method").and_then(Value::as_str).unwrap_or("");
    // Notifications (no id) get no response, whatever the method.
    let id = msg.get("id").filter(|id| !id.is_null()).cloned()?;
    let result = match method {
        "initialize" => {
            // Echo the client's protocol version; every revision with tool
            // support works for us.
            let version = msg
                .pointer("/params/protocolVersion")
                .and_then(Value::as_str)
                .unwrap_or("2025-06-18");
            json!({
                "protocolVersion": version,
                "capabilities": { "tools": {} },
                "serverInfo": {
                    "name": "gamenight",
                    "title": "GameNight",
                    "version": env!("CARGO_PKG_VERSION")
                },
                "instructions": "You are a member of a couch-multiplayer game night. \
                    Call party_status to see who's playing what, list_settings / set_setting \
                    to adjust match settings ('disable items', 'shorter matches'), and \
                    play_next / skip / pause / resume to steer the night."
            })
        }
        "ping" => json!({}),
        "tools/list" => json!({ "tools": tool_definitions() }),
        "tools/call" => {
            let name = msg
                .pointer("/params/name")
                .and_then(Value::as_str)
                .unwrap_or("");
            let empty = json!({});
            let args = msg.pointer("/params/arguments").unwrap_or(&empty);
            let (text, is_error) = match call_tool(client, name, args).await {
                Ok(text) => (text, false),
                Err(text) => (text, true),
            };
            json!({
                "content": [ { "type": "text", "text": text } ],
                "isError": is_error
            })
        }
        other => {
            return Some(json!({
                "jsonrpc": "2.0",
                "id": id,
                "error": { "code": -32601, "message": format!("method not found: {other}") }
            }));
        }
    };
    Some(json!({ "jsonrpc": "2.0", "id": id, "result": result }))
}

/// Serve MCP over a line-delimited transport (stdio in production, anything
/// buffered in tests).
pub async fn serve(
    client: Arc<DaemonClient>,
    reader: impl tokio::io::AsyncBufRead + Unpin,
    mut writer: impl tokio::io::AsyncWrite + Unpin,
) -> std::io::Result<()> {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
    let mut lines = reader.lines();
    while let Some(line) = lines.next_line().await? {
        if line.trim().is_empty() {
            continue;
        }
        let Ok(msg) = serde_json::from_str::<Value>(&line) else {
            let err = json!({
                "jsonrpc": "2.0", "id": null,
                "error": { "code": -32700, "message": "parse error" }
            });
            writer.write_all(format!("{err}\n").as_bytes()).await?;
            writer.flush().await?;
            continue;
        };
        if let Some(response) = handle_message(&client, &msg).await {
            writer.write_all(format!("{response}\n").as_bytes()).await?;
            writer.flush().await?;
        }
    }
    Ok(())
}
