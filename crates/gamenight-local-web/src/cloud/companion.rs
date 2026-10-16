//! Optional outbound transport for hosted phone screens. No inbound LAN port
//! or account login token is exposed to game code.
use super::*;
use base64::{engine::general_purpose::STANDARD, Engine};
use futures_util::StreamExt;
use gamenight_protocol::CompanionScreen;
use serde_json::{json, Value};
use std::{collections::BTreeMap, path::Path};
use tokio_tungstenite::tungstenite::{client::IntoClientRequest, Message};

const MAX_BUNDLE: usize = 2 * 1024 * 1024;
fn collect(
    root: &Path,
    directory: &Path,
    files: &mut BTreeMap<String, String>,
    size: &mut usize,
) -> Result<(), String> {
    if directory
        .strip_prefix(root)
        .map_err(|_| "Invalid bundle directory")?
        .components()
        .count()
        > 12
    {
        return Err("Phone bundle nesting too deep".into());
    }
    for entry in std::fs::read_dir(directory).map_err(|_| "Cannot read phone bundle")? {
        let entry = entry.map_err(|_| "Cannot read phone bundle entry")?;
        let kind = entry
            .file_type()
            .map_err(|_| "Cannot inspect phone bundle entry")?;
        if kind.is_symlink() {
            return Err("Phone bundles cannot contain symlinks".into());
        }
        let path = entry.path();
        if kind.is_dir() {
            collect(root, &path, files, size)?;
            continue;
        }
        if !kind.is_file() {
            continue;
        }
        let relative = path
            .strip_prefix(root)
            .map_err(|_| "Invalid bundle path")?
            .to_string_lossy()
            .replace('\\', "/");
        let ext = relative.rsplit('.').next().unwrap_or("");
        if !matches!(
            ext,
            "html" | "js" | "css" | "json" | "svg" | "png" | "jpg" | "jpeg" | "webp" | "woff2"
        ) {
            continue;
        }
        if relative.len() > 200
            || !relative.split('/').all(|p| {
                !p.is_empty()
                    && p != "."
                    && p != ".."
                    && p.bytes()
                        .all(|c| c.is_ascii_alphanumeric() || b"-_.".contains(&c))
            })
        {
            return Err("Invalid bundle filename".into());
        }
        if entry
            .metadata()
            .map_err(|_| "Cannot inspect phone bundle")?
            .len()
            > 384 * 1024
        {
            return Err("Phone bundle file too large".into());
        }
        let bytes = std::fs::read(&path).map_err(|_| "Cannot read phone bundle file")?;
        let encoded = STANDARD.encode(bytes);
        *size += encoded.len();
        if *size > MAX_BUNDLE || files.len() >= 128 {
            return Err("Phone bundle too large".into());
        }
        files.insert(relative, encoded);
    }
    Ok(())
}

fn bundle(screen: &CompanionScreen, session: &str, title: &str) -> Result<Value, String> {
    let root = Path::new(screen.root.as_deref().ok_or("No phone bundle root")?);
    if !root.is_absolute() {
        return Err("Phone bundle root must be absolute".into());
    }
    let root = root
        .canonicalize()
        .map_err(|_| "Cannot resolve phone bundle")?;
    let mut files = BTreeMap::new();
    collect(&root, &root, &mut files, &mut 0)?;
    let entry = screen
        .entry
        .as_ref()
        .ok_or("No web phone screen declared")?;
    if !files.contains_key(entry) {
        return Err("Phone bundle entry is missing".into());
    }
    Ok(json!({"game":screen.game,"session":session,"title":title,"entry":entry,"files":files}))
}
pub(super) async fn run(bridge: Bridge, state: SharedState) {
    loop {
        tokio::time::sleep(Duration::from_secs(2)).await;
        let hub = state.lock().unwrap().companions.clone();
        let Some((screen, title)) = hub.active().filter(|(s, _)| s.entry.is_some()) else {
            continue;
        };
        let Some(session) = hub.active_session() else {
            continue;
        };
        let Some(token) = bridge.session.lock().unwrap().clone() else {
            continue;
        };
        let Ok(bundle) = bundle(&screen, &session, &title) else {
            continue;
        };
        // Explicit outbound opt-in follows the existing cloud bridge setting.
        let url = format!("{}/v1/lobbies/companion", bridge.origin)
            .replacen("https://", "wss://", 1)
            .replacen("http://", "ws://", 1);
        let Ok(mut request) = url.into_client_request() else {
            continue;
        };
        let Ok(auth) = format!("Bearer {token}").parse() else {
            continue;
        };
        request.headers_mut().insert("authorization", auth);
        let Ok(Ok((mut socket, _))) = tokio::time::timeout(
            Duration::from_secs(10),
            tokio_tungstenite::connect_async(request),
        )
        .await
        else {
            continue;
        };
        if socket
            .send(Message::Text(bundle.to_string()))
            .await
            .is_err()
        {
            continue;
        }
        let (tx, mut rx) = tokio::sync::mpsc::channel::<Value>(128);
        let mut phones: HashMap<String, (u64, PlayerId, tokio::task::JoinHandle<()>)> =
            HashMap::new();
        let mut tick = tokio::time::interval(Duration::from_secs(2));
        loop {
            tokio::select! {
                outbound = rx.recv() => {
                    let Some(outbound) = outbound else { break; };
                    if socket.send(Message::Text(outbound.to_string())).await.is_err() { break; }
                }
                inbound = socket.next() => {
                    let Some(Ok(message)) = inbound else { break; };
                    let Message::Text(text) = message else { if message.is_close() { break; } else { continue; } };
                    let Ok(event) = serde_json::from_str::<Value>(&text) else { break; };
                    let Some(connection) = event["connection"].as_str().filter(|s| s.len()<=64) else { continue; };
                    match event["type"].as_str() {
                        Some("connect") => {
                            if phones.contains_key(connection) || phones.len()>=32 { continue; }
                            let Some(player) = event["player"].as_str().and_then(|p| uuid::Uuid::parse_str(p).ok()).map(PlayerId) else { continue; };
                            if !state.lock().unwrap().bindings.values().any(|p| *p==player) { continue; }
                            let (id, mut messages) = hub.add_phone(screen.game.clone(), player);
                            let sender = tx.clone();
                            let key = connection.to_string();
                            let task = tokio::spawn(async move {
                                while let Some(data) = messages.recv().await {
                                    let Ok(data) = serde_json::from_str::<Value>(&data) else { continue; };
                                    if sender.try_send(json!({"connection":key,"data":data})).is_err() { break; }
                                }
                            });
                            phones.insert(connection.to_string(), (id,player,task));
                        }
                        Some("message") => {
                            if let Some((_,player,_)) = phones.get(connection) {
                                if state.lock().unwrap().bindings.values().any(|p| p==player) {
                                    hub.to_daemon(ClientMessage::CompanionMessage { game: Some(screen.game.clone()), player_id: Some(*player), data:event["data"].clone() });
                                }
                            }
                        }
                        Some("disconnect") => {
                            if let Some((id,_,task)) = phones.remove(connection) { hub.remove_phone(id); task.abort(); }
                        }
                        _ => {}
                    }
                }
                _ = tick.tick() => {
                    if hub.active_session().as_deref()!=Some(&session) || hub.active().is_none_or(|(s,_)| s.game!=screen.game) { break; }
                }
            }
        }
        for (_, (id, _, task)) in phones {
            hub.remove_phone(id);
            task.abort();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    /// External browser harness supplies an isolated daemon and cloud fixture.
    /// HTTP is constructed only here; production configured() still requires HTTPS.
    #[tokio::test]
    #[ignore = "requires isolated hosted companion browser fixture"]
    async fn hosted_browser_fixture() {
        let addr = std::env::var("GAMENIGHT_TEST_DAEMON").unwrap();
        let origin = std::env::var("GAMENIGHT_TEST_CLOUD").unwrap();
        assert!(origin.starts_with("http://127.0.0.1:"));
        assert!(addr.starts_with("127.0.0.1:"));
        let token = std::env::var("GAMENIGHT_TEST_HOST_TOKEN").unwrap();
        let players: Vec<String> =
            serde_json::from_str(&std::env::var("GAMENIGHT_TEST_PLAYERS").unwrap()).unwrap();
        let state = Arc::new(Mutex::new(crate::ServerState::new(addr.clone())));
        for (i, id) in players.iter().enumerate() {
            state.lock().unwrap().bindings.insert(
                format!("cloud_test_{i}"),
                PlayerId(uuid::Uuid::parse_str(id).unwrap()),
            );
        }
        let hub = state.lock().unwrap().companions.clone();
        let reader = tokio::spawn(hub.run(addr));
        let bridge = Bridge {
            origin,
            http: reqwest::Client::new(),
            session: Arc::new(Mutex::new(Some(token))),
            seats: Arc::default(),
            waiting: Arc::default(),
            pairing: Arc::default(),
            pairing_request: Arc::default(),
            refresh: Arc::default(),
        };
        tokio::select! {_=super::run(bridge,state)=>{},_=tokio::time::sleep(Duration::from_secs(90))=>{}}
        reader.abort();
    }
    #[test]
    fn bundle_is_bounded_and_never_follows_symlinks() {
        let root =
            std::env::temp_dir().join(format!("gamenight-companion-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(
            root.join("index.html"),
            "<script src='/assets/companion.js'></script>",
        )
        .unwrap();
        let screen = CompanionScreen {
            game: gamenight_protocol::GameId("test".into()),
            entry: Some("index.html".into()),
            root: Some(root.to_string_lossy().into()),
            app: None,
        };
        let payload = bundle(&screen, "session", "title").unwrap();
        assert_eq!(payload["files"].as_object().unwrap().len(), 1);
        std::fs::write(root.join("too-large.js"), vec![0; 385 * 1024]).unwrap();
        assert!(bundle(&screen, "session", "title").is_err());
        std::fs::remove_file(root.join("too-large.js")).unwrap();
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink("/etc/passwd", root.join("secret.js")).unwrap();
            assert!(bundle(&screen, "session", "title").is_err());
        }
        std::fs::remove_dir_all(root).unwrap();
    }
}
