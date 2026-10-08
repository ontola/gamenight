use super::*;
use std::io::{Read, Write};
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc,
};

fn archive(path: &str, bytes: &[u8]) -> Vec<u8> {
    let mut writer = zip::ZipWriter::new(std::io::Cursor::new(Vec::new()));
    writer
        .start_file(path, zip::write::SimpleFileOptions::default())
        .unwrap();
    writer.write_all(bytes).unwrap();
    writer.finish().unwrap().into_inner()
}

struct Server {
    address: String,
    requests: Arc<AtomicUsize>,
    /// Each request's target (path and query), in arrival order.
    targets: Arc<std::sync::Mutex<Vec<String>>>,
    stop: Arc<std::sync::atomic::AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}
impl Server {
    fn new(game: Vec<u8>, runtime: Vec<u8>) -> Self {
        Self::with_failures(game, runtime, 0)
    }
    fn with_failures(game: Vec<u8>, runtime: Vec<u8>, failures: usize) -> Self {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let address = format!("http://{}", listener.local_addr().unwrap());
        let requests = Arc::new(AtomicUsize::new(0));
        let targets = Arc::new(std::sync::Mutex::new(Vec::new()));
        let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let (count, done, seen) = (requests.clone(), stop.clone(), targets.clone());
        let thread = std::thread::spawn(move || {
            while !done.load(Ordering::SeqCst) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        // Windows accepted sockets inherit the listener's nonblocking mode.
                        stream.set_nonblocking(false).unwrap();
                        stream
                            .set_read_timeout(Some(std::time::Duration::from_secs(3)))
                            .unwrap();
                        let mut request = [0; 4096];
                        let n = stream.read(&mut request).unwrap();
                        let text = String::from_utf8_lossy(&request[..n]).to_string();
                        let target = text.split(' ').nth(1).unwrap_or_default().to_string();
                        seen.lock().unwrap().push(target.clone());
                        let body = if target.starts_with("/runtime.zip") {
                            &runtime
                        } else {
                            &game
                        };
                        if count.fetch_add(1, Ordering::SeqCst) < failures {
                            stream.write_all(b"HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").unwrap();
                            continue;
                        }
                        // The cloud's rule for paid downloads: no grant, no game.
                        if target.starts_with("/paid")
                            && (!target.contains("grant=") || target.contains("grant=expired"))
                        {
                            stream.write_all(b"HTTP/1.1 402 Payment Required\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").unwrap();
                            continue;
                        }
                        write!(
                            stream,
                            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                            body.len()
                        )
                        .unwrap();
                        stream.write_all(body).unwrap();
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(std::time::Duration::from_millis(5))
                    }
                    Err(e) => panic!("{e}"),
                }
            }
        });
        Self {
            address,
            requests,
            targets,
            stop,
            thread: Some(thread),
        }
    }
}

#[tokio::test]
async fn failed_download_waits_for_explicit_retry_then_installs_without_restart() {
    let game = archive("game/main.lua", b"game");
    let runtime = archive("runtime/engine.exe", b"runtime");
    let server = Server::with_failures(game.clone(), runtime.clone(), 1);
    let entry = entry(&server, &game, &runtime);
    let root = std::env::temp_dir().join(format!("gamenight-retry-{}", uuid::Uuid::new_v4()));
    let (handle, signals) = prewarm_channel();
    let (reporter, mut progress) = progress_channel();
    let directory = root.clone();
    let task = tokio::spawn(async move {
        prewarm_queue(vec![entry], &directory, Some(signals), Some(reporter)).await
    });
    tokio::time::timeout(std::time::Duration::from_secs(5), async {
        while progress.recv().await.unwrap().state != InstallState::Failed {}
    })
    .await
    .unwrap();
    assert!(!task.is_finished());
    assert_eq!(server.requests.load(Ordering::SeqCst), 1);
    handle.prioritize("first-game");
    let results = tokio::time::timeout(std::time::Duration::from_secs(5), task)
        .await
        .unwrap()
        .unwrap();
    assert!(results[0].outcome.is_err());
    assert!(results[1].outcome.is_ok());
    assert_eq!(results.len(), 2);
    let mut states = Vec::new();
    while let Ok(status) = progress.try_recv() {
        states.push(status.state);
    }
    assert!(states.contains(&InstallState::Queued));
    assert_eq!(states.last(), Some(&InstallState::Installed));
    tokio::fs::remove_dir_all(root).await.unwrap();
}
impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        let result = self.thread.take().unwrap().join();
        if !std::thread::panicking() {
            result.expect("test server failed");
        }
    }
}
fn entry(server: &Server, game: &[u8], runtime: &[u8]) -> CatalogEntry {
    serde_json::from_value(serde_json::json!({
        "id":"first-game", "title":"First", "players":{"min":2,"max":4},
        "price":"free", "integration":{"level":"integrated","protocol":1},
        "downloads": { (gamenight_catalog::current_platform()): {
            "url":format!("{}/game.zip",server.address), "sha256":hex(&Sha256::digest(game)),
            "entrypoint":"game/main.lua", "runtime": {
                "id":"shared-runtime", "url":format!("{}/runtime.zip",server.address),
                "sha256":hex(&Sha256::digest(runtime)), "entrypoint":"runtime/engine.exe", "argument":"game_directory"
            }
        }}
    })).unwrap()
}

#[tokio::test]
async fn shared_runtime_first_install_offline_restart_and_missing_file_repair() {
    let game = archive("game/main.lua", b"game");
    let runtime = archive("runtime/engine.exe", b"runtime");
    let server = Server::new(game.clone(), runtime.clone());
    let mut entry = entry(&server, &game, &runtime);
    let root = std::env::temp_dir().join(format!("gamenight-download-{}", uuid::Uuid::new_v4()));
    let (tx, mut rx) = progress_channel();
    let first = ensure_installed_reporting(&entry, &root, Some(&tx))
        .await
        .unwrap();
    let spec = first.launch_spec();
    assert!(spec.command.ends_with("engine.exe"));
    assert_eq!(
        spec.args,
        vec![first.executable.parent().unwrap().display().to_string()]
    );
    assert_eq!(spec.cwd.as_ref(), spec.args.first());
    let mut states = Vec::new();
    while let Ok(status) = rx.try_recv() {
        states.push(status.state);
    }
    assert!(states.contains(&InstallState::Downloading));
    assert_eq!(states.last(), Some(&InstallState::Installed));
    assert_eq!(server.requests.load(Ordering::SeqCst), 2);
    entry.id = "second-game".into();
    let second = ensure_installed(&entry, &root).await.unwrap();
    assert_eq!(server.requests.load(Ordering::SeqCst), 3, "runtime reused");
    assert_eq!(first.launch_spec().command, second.launch_spec().command);
    tokio::fs::remove_file(&second.executable).await.unwrap();
    assert!(already_installed(&entry, &root).await.is_none());
    ensure_installed(&entry, &root).await.unwrap();
    assert_eq!(
        server.requests.load(Ordering::SeqCst),
        4,
        "missing game repaired without fetching runtime"
    );
    drop(server);
    ensure_installed(&entry, &root)
        .await
        .expect("cached install works with server offline");
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn bad_update_keeps_previous_version_and_never_reports_ready() {
    let game = archive("game/main.lua", b"game");
    let runtime = archive("runtime/engine.exe", b"runtime");
    let server = Server::new(game.clone(), runtime.clone());
    let mut entry = entry(&server, &game, &runtime);
    let root = std::env::temp_dir().join(format!("gamenight-corrupt-{}", uuid::Uuid::new_v4()));
    let first = ensure_installed(&entry, &root).await.unwrap();
    entry
        .downloads
        .get_mut(gamenight_catalog::current_platform())
        .unwrap()
        .sha256 = "f".repeat(64);
    let (tx, mut rx) = progress_channel();
    assert!(matches!(
        ensure_installed_reporting(&entry, &root, Some(&tx)).await,
        Err(InstallError::HashMismatch { .. })
    ));
    let mut last = None;
    while let Ok(status) = rx.try_recv() {
        assert_ne!(status.state, InstallState::Installed);
        last = Some(status.state);
    }
    assert_eq!(last, Some(InstallState::Failed));
    assert!(first.executable.is_file());
    assert!(already_installed(&entry, &root).await.is_none());
    assert_eq!(
        std::fs::read_dir(root.join(&entry.id)).unwrap().count(),
        1,
        "failed staging cleaned up"
    );
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn archive_without_declared_entrypoint_is_not_installed() {
    let game = archive("wrong.lua", b"game");
    let runtime = archive("runtime/engine.exe", b"runtime");
    let server = Server::new(game.clone(), runtime.clone());
    let entry = entry(&server, &game, &runtime);
    let root = std::env::temp_dir().join(format!("gamenight-missing-{}", uuid::Uuid::new_v4()));
    assert!(matches!(
        ensure_installed(&entry, &root).await,
        Err(InstallError::Extract(_))
    ));
    assert!(already_installed(&entry, &root).await.is_none());
    tokio::fs::remove_dir_all(root).await.unwrap();
}

fn paid_entry(server: &Server, game: &[u8]) -> CatalogEntry {
    serde_json::from_value(serde_json::json!({
        "id":"paid-game", "title":"Paid", "players":{"min":1,"max":4},
        "price":"paid", "integration":{"level":"integrated","protocol":1},
        "downloads": { (gamenight_catalog::current_platform()): {
            "url":format!("{}/paid.zip",server.address), "sha256":hex(&Sha256::digest(game)),
            "entrypoint":"game/main.lua"
        }}
    }))
    .unwrap()
}

#[tokio::test]
async fn paid_game_downloads_only_with_a_grant_which_never_leaks() {
    let game = archive("game/main.lua", b"paid");
    let server = Server::new(game.clone(), Vec::new());
    let entry = paid_entry(&server, &game);
    let root = std::env::temp_dir().join(format!("gamenight-paid-{}", uuid::Uuid::new_v4()));
    assert!(matches!(
        ensure_installed(&entry, &root).await,
        Err(InstallError::NotEligible)
    ));
    assert_eq!(server.requests.load(Ordering::SeqCst), 0);

    let (tx, mut rx) = progress_channel();
    let installed = ensure_installed_granted(&entry, &root, Some("tok-1.a"), Some(&tx))
        .await
        .unwrap();
    assert!(installed.executable.is_file());
    assert_eq!(
        server.targets.lock().unwrap().as_slice(),
        ["/paid.zip?grant=tok-1.a"]
    );
    while let Ok(status) = rx.try_recv() {
        assert!(!status.label.unwrap_or_default().contains("tok-1"));
    }
    let marker = std::fs::read_to_string(installed.dir.join(".gamenight-install.json")).unwrap();
    assert!(
        !marker.contains("tok-1"),
        "the grant is not written to disk"
    );
    // Free startup scans skip paid games; a just-reported install resolves.
    assert!(already_installed(&entry, &root).await.is_none());
    assert!(already_installed_granted(&entry, &root).await.is_some());
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[tokio::test]
async fn a_refused_grant_is_a_402_that_never_names_the_token() {
    let game = archive("game/main.lua", b"paid");
    let server = Server::new(game.clone(), Vec::new());
    let entry = paid_entry(&server, &game);
    let root = std::env::temp_dir().join(format!("gamenight-402-{}", uuid::Uuid::new_v4()));
    let (tx, mut rx) = progress_channel();
    let err = ensure_installed_granted(&entry, &root, Some("expired"), Some(&tx))
        .await
        .unwrap_err()
        .to_string();
    assert!(err.contains("402"), "{err}");
    assert!(!err.contains("expired"), "{err}");
    let mut last = None;
    while let Ok(status) = rx.try_recv() {
        last = Some(status);
    }
    let last = last.unwrap();
    assert_eq!(last.state, InstallState::Failed);
    assert!(!last.label.unwrap().contains("expired"));
    let _ = tokio::fs::remove_dir_all(root).await;
}

#[tokio::test]
async fn a_grant_queues_a_paid_game_with_the_latest_token() {
    let game = archive("game/main.lua", b"paid");
    let server = Server::new(game.clone(), Vec::new());
    let entry = paid_entry(&server, &game);
    let root = std::env::temp_dir().join(format!("gamenight-grants-{}", uuid::Uuid::new_v4()));
    let (handle, signals) = prewarm_channel();
    let (reporter, mut progress) = progress_channel();
    let directory = root.clone();
    let task = tokio::spawn(async move {
        prewarm_queue(vec![entry], &directory, Some(signals), Some(reporter)).await
    });
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    assert!(
        !task.is_finished(),
        "paid games keep the prewarm waiting for grants"
    );
    assert_eq!(server.requests.load(Ordering::SeqCst), 0);

    // Polls refresh the token; the download uses whichever is newest.
    handle.set_grants(BTreeMap::from([("paid-game".into(), "first".into())]));
    handle.set_grants(BTreeMap::from([("paid-game".into(), "fresh".into())]));
    drop(handle);
    let results = tokio::time::timeout(std::time::Duration::from_secs(5), task)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(results.len(), 1);
    assert!(results[0].outcome.is_ok());
    assert_eq!(
        server.targets.lock().unwrap().as_slice(),
        ["/paid.zip?grant=fresh"]
    );
    let mut states = Vec::new();
    while let Ok(status) = progress.try_recv() {
        states.push(status.state);
    }
    assert_eq!(states.first(), Some(&InstallState::Queued));
    assert_eq!(states.last(), Some(&InstallState::Installed));
    tokio::fs::remove_dir_all(root).await.unwrap();
}

#[test]
fn a_revoked_grant_reports_the_game_unavailable_and_a_new_one_retries_it() {
    let server = Server::new(Vec::new(), Vec::new());
    let entry = paid_entry(&server, b"paid");
    let (reporter, mut progress) = progress_channel();
    let (handle, mut rx) = prewarm_channel();
    let mut state = Prewarm {
        queue: VecDeque::new(),
        failed: HashMap::from([(entry.id.clone(), entry.clone())]),
        locked: HashMap::new(),
        grants: BTreeMap::from([(entry.id.clone(), "old".into())]),
        reporter: Some(reporter),
    };
    handle.set_grants(BTreeMap::new());
    apply_signals(&mut state, None, &mut rx);
    assert!(state.failed.is_empty() && state.queue.is_empty());
    assert!(state.locked.contains_key("paid-game"));
    let status = progress.try_recv().unwrap();
    assert_eq!(status.state, InstallState::Failed);
    assert!(status.label.unwrap().contains("not eligible"));

    handle.set_grants(BTreeMap::from([("paid-game".into(), "new".into())]));
    apply_signals(&mut state, None, &mut rx);
    assert_eq!(
        state.queue.front().map(|e| e.id.as_str()),
        Some("paid-game")
    );
    assert_eq!(progress.try_recv().unwrap().state, InstallState::Queued);
    // A refreshed token for the same game is not a new request.
    handle.set_grants(BTreeMap::from([("paid-game".into(), "newer".into())]));
    apply_signals(&mut state, None, &mut rx);
    assert_eq!(state.queue.len(), 1);
    assert_eq!(state.grants["paid-game"], "newer");
    assert!(format!("{:?}", PrewarmSignal::Grants(state.grants.clone())).contains("paid-game"));
    assert!(!format!("{:?}", PrewarmSignal::Grants(state.grants.clone())).contains("newer"));
}
