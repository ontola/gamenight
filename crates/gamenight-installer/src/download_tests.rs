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
    stop: Arc<std::sync::atomic::AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}
impl Server {
    fn new(game: Vec<u8>, runtime: Vec<u8>) -> Self {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let address = format!("http://{}", listener.local_addr().unwrap());
        let requests = Arc::new(AtomicUsize::new(0));
        let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let (count, done) = (requests.clone(), stop.clone());
        let thread = std::thread::spawn(move || {
            while !done.load(Ordering::SeqCst) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        stream
                            .set_read_timeout(Some(std::time::Duration::from_secs(3)))
                            .unwrap();
                        let mut request = [0; 4096];
                        let n = stream.read(&mut request).unwrap();
                        let body =
                            if String::from_utf8_lossy(&request[..n]).contains("/runtime.zip") {
                                &runtime
                            } else {
                                &game
                            };
                        count.fetch_add(1, Ordering::SeqCst);
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
            stop,
            thread: Some(thread),
        }
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        self.thread.take().unwrap().join().unwrap();
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
