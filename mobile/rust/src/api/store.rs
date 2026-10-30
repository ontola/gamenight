//! The phone's own player store: this phone's player's settings and progress
//! per game, in the same Atomic Data store the GameNight host uses
//! (`gamenight-store`). A guest's values live here, so they follow the phone
//! from computer to computer. Once the phone is signed in, its player's
//! records live in the account's drive on the cloud's Atomic hub and sync
//! with it, so the hosts the account plays on see the same values.

use std::collections::BTreeMap;

use flutter_rust_bridge::frb;
use gamenight_core::SavedPlayerData;
use gamenight_protocol::SettingValue;
use tokio::sync::Mutex;

/// The phone's own player before it signs in.
const OWNER: &str = "me";

#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// An open store. One per app; open it once at startup.
#[frb(opaque)]
pub struct PhoneStore {
    store: Mutex<gamenight_store::Store>,
    /// Who the phone's player is in the store: `me`, or the signed-in
    /// account (`account:<id>`).
    owner: Mutex<String>,
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
            owner: Mutex::new(OWNER.into()),
        })
    }

    /// Be the signed-in account's player (`account:<id>`), whose drive was
    /// linked before; `None` after signing out.
    pub async fn use_account(&self, owner: Option<String>) {
        let linked = match &owner {
            Some(o) => self.store.lock().await.linked_drive(o).is_some(),
            None => false,
        };
        *self.owner.lock().await = match owner {
            Some(o) if linked => o,
            _ => OWNER.into(),
        };
    }

    /// After signing in: the account's records live in `drive` on the hub
    /// at `url` (`wss://host/atomic/ws`) from now on. Takes what the account
    /// already has, moves this phone's own player's values in, and sends
    /// them up.
    pub async fn link_account(
        &self,
        url: String,
        owner: String,
        drive: String,
    ) -> Result<(), String> {
        let mut store = self.store.lock().await;
        if store.linked_drive(&owner) != Some(drive.as_str()) {
            store
                .sync_hub(&url, &drive)
                .await
                .map_err(|e| e.to_string())?;
            store
                .link_from(OWNER, &owner, &drive)
                .await
                .map_err(|e| e.to_string())?;
        }
        *self.owner.lock().await = owner;
        store
            .sync_hub(&url, &drive)
            .await
            .map_err(|e| e.to_string())?;
        Ok(())
    }

    /// Sync the signed-in account's drive with the hub at `url`. True when
    /// something came in.
    pub async fn sync(&self, url: String) -> Result<bool, String> {
        let owner = self.owner.lock().await.clone();
        let mut store = self.store.lock().await;
        let Some(drive) = store.linked_drive(&owner).map(str::to_string) else {
            return Ok(false);
        };
        let (report, _) = store
            .sync_hub(&url, &drive)
            .await
            .map_err(|e| e.to_string())?;
        Ok(report.received > 0)
    }

    /// This phone's Atomic agent, which signs every change.
    pub async fn agent(&self) -> Option<String> {
        self.store.lock().await.agent()
    }

    /// Every game's saved settings, as a JSON object: game -> key -> value.
    pub async fn all_settings(&self) -> Result<String, String> {
        let owner = self.owner.lock().await.clone();
        let saved = self
            .store
            .lock()
            .await
            .load()
            .await
            .map_err(|e| e.to_string())?;
        let mine = saved.settings.get(&owner).cloned().unwrap_or_default();
        serde_json::to_string(&mine).map_err(|e| e.to_string())
    }

    /// Replace this player's settings for `game` with `json` (key -> value).
    pub async fn set_settings(&self, game: String, json: String) -> Result<(), String> {
        let values: BTreeMap<String, SettingValue> =
            serde_json::from_str(&json).map_err(|e| e.to_string())?;
        let owner = self.owner.lock().await.clone();
        self.store
            .lock()
            .await
            .put_settings(&owner, &game, &values)
            .await
            .map_err(|e| e.to_string())
    }

    /// This player's saved progress in `game`, if any.
    pub async fn progress(&self, game: String) -> Result<Option<PhoneProgress>, String> {
        let owner = self.owner.lock().await.clone();
        let saved = self
            .store
            .lock()
            .await
            .load()
            .await
            .map_err(|e| e.to_string())?;
        Ok(saved
            .data
            .get(&owner)
            .and_then(|games| games.get(&game))
            .map(|saved| PhoneProgress {
                json: saved.data.to_string(),
                revision: saved.revision,
            }))
    }

    /// Keep this player's progress in `game`.
    pub async fn set_progress(
        &self,
        game: String,
        json: String,
        revision: u64,
    ) -> Result<(), String> {
        let data = serde_json::from_str(&json).map_err(|e| e.to_string())?;
        let owner = self.owner.lock().await.clone();
        self.store
            .lock()
            .await
            .put_data(&owner, &game, &SavedPlayerData { data, revision })
            .await
            .map_err(|e| e.to_string())
    }
}
