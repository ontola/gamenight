//! Web-owned profile bindings, polled off the render thread.
use gamenight_protocol::PlayerId;
use std::{
    collections::{HashMap, HashSet},
    sync::{mpsc, Arc, Mutex},
    time::Duration,
};
#[derive(Default, Clone, serde::Deserialize)]
pub struct Room {
    #[serde(default)]
    pub room_code: String,
    #[serde(default)]
    pub pending: Vec<Pending>,
}
#[derive(Default, Clone, serde::Deserialize)]
pub struct Pending {
    pub id: String,
    pub profile: PendingProfile,
    pub expires: u64,
}
#[derive(Default, Clone, serde::Deserialize)]
pub struct PendingProfile {
    pub display_name: String,
    pub skin_color: String,
    pub avatar: String,
}
#[derive(Default, Clone, serde::Deserialize)]
pub struct Snapshot {
    #[serde(default)]
    pub cloud: bool,
    #[serde(default)]
    pub pairing_urls: HashMap<PlayerId, String>,
    #[serde(default)]
    pub room: Option<Room>,
    pub linked: HashSet<PlayerId>,
    pub revisions: HashMap<PlayerId, u64>,
}
impl Snapshot {
    pub fn join_url(&self, player: PlayerId, local_base: &str) -> Option<String> {
        if self.cloud { return self.pairing_urls.get(&player).cloned(); }
        let revision = self.revisions.get(&player).copied().unwrap_or(0);
        let base = local_base.trim_end_matches('/');
        let base = if base.strip_prefix("http://").or_else(|| base.strip_prefix("https://")).is_some_and(|s| !s.contains('/')) { format!("{base}/studio") } else { base.to_owned() };
        Some(format!("{base}?claim={}&link_revision={revision}", player.0))
    }
}
#[derive(bevy::prelude::Resource)]
pub struct PlayerLinks {
    pub state: Arc<Mutex<Option<Snapshot>>>,
    unlink: mpsc::Sender<PlayerId>,
    pickup: mpsc::Sender<(String, PlayerId)>,
}
impl Default for PlayerLinks {
    fn default() -> Self {
        let state = Arc::new(Mutex::new(None));
        let shared = state.clone();
        let (unlink, rx) = mpsc::channel::<PlayerId>();
        let (pickup, pickups) = mpsc::channel::<(String, PlayerId)>();
        std::thread::spawn(move || loop {
            while let Ok((id, player)) = pickups.try_recv() {
                let _ = request("POST", &format!("/api/room-pickup/{id}/{}", player.0));
            }
            while let Ok(id) = rx.try_recv() {
                let _ = request("POST", &format!("/api/player-links/{}/unlink", id.0));
            }
            let snapshot = request("GET", "/api/player-links")
                .and_then(|body| serde_json::from_str(&body).ok());
            *shared.lock().unwrap() = snapshot;
            std::thread::sleep(Duration::from_millis(500));
        });
        Self {
            state,
            unlink,
            pickup,
        }
    }
}
impl PlayerLinks {
    pub fn snapshot(&self) -> Option<Snapshot> {
        self.state.lock().unwrap().clone()
    }
    pub fn pickup(&self, id: String, player: PlayerId) {
        let _ = self.pickup.send((id, player));
    }
    pub fn unlink(&self, player: PlayerId) {
        let _ = self.unlink.send(player);
    }
}
fn request(method: &str, path: &str) -> Option<String> {
    use std::io::{Read, Write};
    let base =
        std::env::var("GAMENIGHT_JOIN_URL").unwrap_or_else(|_| gamenight_protocol::web_base_url());
    let original = base.strip_prefix("http://")?.split('/').next()?;
    let local_pickup = path.starts_with("/api/room-pickup/");
    let loopback = format!(
        "127.0.0.1:{}",
        original.rsplit_once(':').map(|(_, p)| p).unwrap_or("80")
    );
    let host = if local_pickup {
        loopback.as_str()
    } else {
        original
    };
    use std::net::ToSocketAddrs;
    let addr = host.to_socket_addrs().ok()?.next()?;
    let mut stream = std::net::TcpStream::connect_timeout(&addr, Duration::from_secs(2)).ok()?;
    stream.set_read_timeout(Some(Duration::from_secs(2))).ok()?;
    stream
        .set_write_timeout(Some(Duration::from_secs(2)))
        .ok()?;
    write!(stream, "{method} {path} HTTP/1.1\r\nHost: {host}\r\nX-GameNight-Local-Pickup: 1\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").ok()?;
    let mut raw = String::new();
    stream.read_to_string(&mut raw).ok()?;
    let (header, body) = raw.split_once("\r\n\r\n")?;
    if !header.split_whitespace().nth(1)?.starts_with('2') {
        return None;
    }
    Some(body.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cloud_qr_uses_hosted_ticket_and_never_local_fallback() {
        let player = PlayerId::default();
        let mut snapshot = Snapshot { cloud: true, ..Default::default() };
        assert_eq!(snapshot.join_url(player, "http://localhost:7913"), None);
        let url = "https://gamenight.ontola.io/studio#pair=opaque-ticket";
        snapshot.pairing_urls.insert(player, url.into());
        assert_eq!(snapshot.join_url(player, "http://localhost:7913").as_deref(), Some(url));
    }

    #[test]
    fn offline_qr_has_scanner_recognized_studio_path() {
        let player = PlayerId::default();
        let snapshot = Snapshot::default();
        assert!(snapshot.join_url(player, "http://192.168.0.85:7913/").unwrap()
            .starts_with("http://192.168.0.85:7913/studio?claim="));
    }
}
