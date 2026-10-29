//! The phone's own player store: this phone's player's settings and progress
//! per game, in the same Atomic Data store the GameNight host uses
//! (`gamenight-store`). A guest's values live here, so they follow the phone
//! from computer to computer; later this store syncs with the host and the
//! account's hub.

use std::collections::BTreeMap;

use flutter_rust_bridge::frb;
use gamenight_core::SavedPlayerData;
use gamenight_protocol::SettingValue;
use tokio::sync::Mutex;

/// Everything on the phone belongs to the phone's own player.
const OWNER: &str = "me";

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// An open store. One per app; open it once at startup.
#[frb(opaque)]
pub struct PhoneStore {
    store: Mutex<gamenight_store::Store>,
}

/// Saved progress for one game: the game's JSON and its revision.
pub struct PhoneProgress {
    pub json: String,
    pub revision: u64,
}

impl PhoneStore {
    /// Open (or create) the store in `dir`, the app's private documents
    /// directory.
    pub async fn open(dir: String) -> Result<PhoneStore, String> {
        let store = gamenight_store::Store::open(std::path::Path::new(&dir))
            .await
            .map_err(|e| e.to_string())?;
        Ok(PhoneStore {
            store: Mutex::new(store),
        })
    }

    /// This phone's Atomic agent, which signs every change.
    pub async fn agent(&self) -> Option<String> {
        self.store.lock().await.agent()
    }

    /// Every game's saved settings, as a JSON object: game -> key -> value.
    pub async fn all_settings(&self) -> Result<String, String> {
        let saved = self.store.lock().await.load().await.map_err(|e| e.to_string())?;
        let mine = saved.settings.get(OWNER).cloned().unwrap_or_default();
        serde_json::to_string(&mine).map_err(|e| e.to_string())
    }

    /// Replace this player's settings for `game` with `json` (key -> value).
    pub async fn set_settings(&self, game: String, json: String) -> Result<(), String> {
        let values: BTreeMap<String, SettingValue> =
            serde_json::from_str(&json).map_err(|e| e.to_string())?;
        self.store
            .lock()
            .await
            .put_settings(OWNER, &game, &values)
            .await
            .map_err(|e| e.to_string())
    }

    /// This player's saved progress in `game`, if any.
    pub async fn progress(&self, game: String) -> Result<Option<PhoneProgress>, String> {
        let saved = self.store.lock().await.load().await.map_err(|e| e.to_string())?;
        Ok(saved
            .data
            .get(OWNER)
            .and_then(|games| games.get(&game))
            .map(|saved| PhoneProgress {
                json: saved.data.to_string(),
                revision: saved.revision,
            }))
    }

    /// Keep this player's progress in `game`.
    pub async fn set_progress(&self, game: String, json: String, revision: u64) -> Result<(), String> {
        let data = serde_json::from_str(&json).map_err(|e| e.to_string())?;
        self.store
            .lock()
            .await
            .put_data(OWNER, &game, &SavedPlayerData { data, revision })
            .await
            .map_err(|e| e.to_string())
    }
}
