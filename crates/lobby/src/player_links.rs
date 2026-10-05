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
pub struct LobbyChoice {
    pub id: String,
    pub title: String,
}
#[derive(Default, Clone, serde::Deserialize)]
pub struct Snapshot {
    #[serde(default)]
    pub lobbies: Vec<LobbyChoice>,
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
    pub fn join_url(&self, player: PlayerId, _local_base: &str) -> Option<String> {
        self.pairing_urls.get(&player).cloned()
    }
}
#[derive(bevy::prelude::Resource)]
pub struct PlayerLinks {
    pub state: Arc<Mutex<Option<Snapshot>>>,
    unlink: mpsc::Sender<PlayerId>,
    pickup: mpsc::Sender<(String, PlayerId)>,
    choose: mpsc::Sender<String>,
    notice: Arc<Mutex<String>>,
}
impl Default for PlayerLinks {
    fn default() -> Self {
        let state = Arc::new(Mutex::new(None));
        let shared = state.clone();
        let (unlink, rx) = mpsc::channel::<PlayerId>();
        let (pickup, pickups) = mpsc::channel::<(String, PlayerId)>();
        let (choose, choices) = mpsc::channel::<String>();
        let notice = Arc::new(Mutex::new(String::new()));
        let result = notice.clone();
        std::thread::spawn(move || loop {
            while let Ok(id) = choices.try_recv() {
                let saved = request_body("POST", "/api/host/lobby", &serde_json::json!({"id":id}).to_string()).is_some();
                *result.lock().unwrap() = if saved { "Saved for next launch." } else { "Could not save. Try again." }.into();
            }
            while let Ok((id, player)) = pickups.try_recv() {
                let _ = request("POST", &format!("/api/room-pickup/{id}/{}", player.0));
            }
            while let Ok(id) = rx.try_recv() {
                let _ = request("POST", &format!("/api/player-links/{}/unlink", id.0));
            }
            let mut snapshot: Option<Snapshot> = request("GET", "/api/player-links")
                .and_then(|body| serde_json::from_str(&body).ok());
            if let Some(snapshot) = snapshot.as_mut() {
                snapshot.lobbies = request("GET", "/api/host/lobby")
                    .and_then(|body| serde_json::from_str::<serde_json::Value>(&body).ok())
                    .and_then(|value| serde_json::from_value(value["choices"].clone()).ok()).unwrap_or_default();
            }
            *shared.lock().unwrap() = snapshot;
            std::thread::sleep(Duration::from_millis(500));
        });
        Self {
            state,
            unlink,
            pickup,
            choose,
            notice,
        }
    }
}
impl PlayerLinks {
    pub fn choose_lobby(&self, id: String) {
        *self.notice.lock().unwrap() = "Saving…".into();
        let _ = self.choose.send(id);
    }
    pub fn lobby_notice(&self) -> String { self.notice.lock().unwrap().clone() }
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
fn request(method: &str, path: &str) -> Option<String> { request_body(method,path,"") }
fn request_body(method: &str, path: &str, body: &str) -> Option<String> {
    use std::io::{Read, Write};
    let base =
        std::env::var("GAMENIGHT_LINKS_URL").unwrap_or_else(|_| format!("http://127.0.0.1:{}", gamenight_protocol::DEFAULT_WEB_PORT));
    let original = base.strip_prefix("http://")?.split('/').next()?;
    let loopback = format!(
        "127.0.0.1:{}",
        original.rsplit_once(':').map(|(_, p)| p).unwrap_or("80")
    );
    let host = loopback.as_str();
    use std::net::ToSocketAddrs;
    let addr = host.to_socket_addrs().ok()?.next()?;
    let mut stream = std::net::TcpStream::connect_timeout(&addr, Duration::from_secs(2)).ok()?;
    stream.set_read_timeout(Some(Duration::from_secs(2))).ok()?;
    stream
        .set_write_timeout(Some(Duration::from_secs(2)))
        .ok()?;
    write!(stream, "{method} {path} HTTP/1.1\r\nHost: {host}\r\nX-GameNight-Local-Pickup: 1\r\nX-GameNight-Host: 1\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).ok()?;
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
    fn offline_guests_do_not_get_a_broken_phone_link() {
        let player = PlayerId::default();
        let snapshot = Snapshot::default();
        assert!(snapshot.join_url(player, "http://192.168.0.85:7913/").is_none());
    }
}
