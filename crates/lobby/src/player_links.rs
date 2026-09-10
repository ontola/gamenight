//! Web-owned profile bindings, polled off the render thread.
use gamenight_protocol::PlayerId;
use std::{
    collections::{HashMap, HashSet},
    sync::{mpsc, Arc, Mutex},
    time::Duration,
};
#[derive(Default, Clone, serde::Deserialize)]
pub struct Snapshot {
    pub linked: HashSet<PlayerId>,
    pub revisions: HashMap<PlayerId, u64>,
}
#[derive(bevy::prelude::Resource)]
pub struct PlayerLinks {
    pub state: Arc<Mutex<Option<Snapshot>>>,
    unlink: mpsc::Sender<PlayerId>,
}
impl Default for PlayerLinks {
    fn default() -> Self {
        let state = Arc::new(Mutex::new(None));
        let shared = state.clone();
        let (unlink, rx) = mpsc::channel::<PlayerId>();
        std::thread::spawn(move || loop {
            while let Ok(id) = rx.try_recv() {
                let _ = request("POST", &format!("/api/player-links/{}/unlink", id.0));
            }
            let snapshot = request("GET", "/api/player-links")
                .and_then(|body| serde_json::from_str(&body).ok());
            *shared.lock().unwrap() = snapshot;
            std::thread::sleep(Duration::from_millis(500));
        });
        Self { state, unlink }
    }
}
impl PlayerLinks {
    pub fn snapshot(&self) -> Option<Snapshot> {
        self.state.lock().unwrap().clone()
    }
    pub fn unlink(&self, player: PlayerId) {
        let _ = self.unlink.send(player);
    }
}
fn request(method: &str, path: &str) -> Option<String> {
    use std::io::{Read, Write};
    let base =
        std::env::var("GAMENIGHT_JOIN_URL").unwrap_or_else(|_| gamenight_protocol::web_base_url());
    let host = base.strip_prefix("http://")?.split('/').next()?;
    use std::net::ToSocketAddrs;
    let addr = host.to_socket_addrs().ok()?.next()?;
    let mut stream = std::net::TcpStream::connect_timeout(&addr, Duration::from_secs(2)).ok()?;
    stream.set_read_timeout(Some(Duration::from_secs(2))).ok()?;
    stream
        .set_write_timeout(Some(Duration::from_secs(2)))
        .ok()?;
    write!(stream, "{method} {path} HTTP/1.1\r\nHost: {host}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").ok()?;
    let mut raw = String::new();
    stream.read_to_string(&mut raw).ok()?;
    let (header, body) = raw.split_once("\r\n\r\n")?;
    if !header.split_whitespace().nth(1)?.starts_with('2') {
        return None;
    }
    Some(body.to_owned())
}
