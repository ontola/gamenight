//! The host's own storage: players' settings and progress, kept in an
//! embedded [Atomic Data](https://docs.atomicdata.dev) store (`atomic_lib`).
//!
//! Every host has its own Atomic agent (a key pair, kept in `agent.secret`
//! next to the database) and a private drive. Each profile's data for one
//! game is one resource in that drive, changed through signed commits, so
//! there is a history per record and the same data can later sync to the
//! player's phone and to a hub with Atomic's own sync protocol.
//!
//! Games never see any of this: the daemon reads and writes it, and games
//! only get `player_settings` / `player_data` for the players in the room.

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};

use atomic_lib::{Db, Storelike, Value};
use gamenight_core::{PlayerDataStore, PlayerSettingsStore, SavedPlayerData};
use gamenight_protocol::{GameId, SettingValue};
use tokio::sync::{mpsc, oneshot};
use tracing::{info, warn};

/// One profile's settings and progress for one game.
const PLAYER_GAME: &str = "https://gamenight.ontola.io/ns/PlayerGame";
const OWNER: &str = "https://gamenight.ontola.io/ns/owner";
const GAME: &str = "https://gamenight.ontola.io/ns/game";
/// The profile's own setting values, as a JSON object.
const SETTINGS: &str = "https://gamenight.ontola.io/ns/settings";
/// What the game last stored with `save_player_data`, as JSON.
const DATA: &str = "https://gamenight.ontola.io/ns/data";
const DATA_REVISION: &str = "https://gamenight.ontola.io/ns/dataRevision";

pub type Error = Box<dyn std::error::Error + Send + Sync>;
pub type Result<T> = std::result::Result<T, Error>;

fn atomic(e: atomic_lib::errors::AtomicError) -> Error {
    e.to_string().into()
}

/// Everything saved, as the night loads it.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct Saved {
    pub settings: PlayerSettingsStore,
    pub data: PlayerDataStore,
}

/// An open store. Async; the daemon talks to it through [`StoreHandle`].
pub struct Store {
    db: Db,
    drive: String,
    /// (owner, game) -> subject of its resource.
    records: HashMap<(String, String), String>,
}

impl Store {
    /// Open the store in `dir`, creating the database, agent and drive the
    /// first time.
    pub async fn open(dir: &Path) -> Result<Self> {
        std::fs::create_dir_all(dir)?;
        let secret_path = dir.join("agent.secret");
        let db = Db::init_redb_file(dir, None, &dir.join("uploads"))
            .await
            .map_err(atomic)?;
        let drive = match std::fs::read_to_string(&secret_path) {
            Ok(secret) => {
                db.load_agent_from_secret(secret.trim())
                    .await
                    .map_err(atomic)?;
                match db.get_active_drive() {
                    Some(drive) => drive,
                    None => db.ensure_private_drive().await.map_err(atomic)?,
                }
            }
            Err(_) => {
                let (agent, drive) = db.setup("GameNight host").await.map_err(atomic)?;
                let secret = agent.build_secret().map_err(atomic)?;
                let temporary = secret_path.with_extension("tmp");
                std::fs::write(&temporary, secret)?;
                std::fs::rename(temporary, &secret_path)?;
                db.flush().map_err(atomic)?;
                drive
            }
        };
        let mut store = Self {
            db,
            drive,
            records: HashMap::new(),
        };
        for resource in store
            .db
            .get_children(&store.drive, Some(PLAYER_GAME))
            .await
            .map_err(atomic)?
        {
            if let (Ok(owner), Ok(game)) = (resource.get(OWNER), resource.get(GAME)) {
                store.records.insert(
                    (owner.to_string(), game.to_string()),
                    resource.get_subject().to_string(),
                );
            }
        }
        info!(dir = %dir.display(), records = store.records.len(), "player store open");
        Ok(store)
    }

    /// The host's Atomic agent, which signs every change.
    pub fn agent(&self) -> Option<String> {
        self.db
            .get_default_agent()
            .ok()
            .map(|a| a.subject.to_string())
    }

    /// Everything saved for every profile.
    pub async fn load(&self) -> Result<Saved> {
        let mut saved = Saved::default();
        for ((owner, game), subject) in &self.records {
            let resource = self
                .db
                .get_resource(&subject.as_str().into())
                .await
                .map_err(atomic)?;
            if let Ok(settings) = resource.get(SETTINGS) {
                match serde_json::from_str::<BTreeMap<String, SettingValue>>(&settings.to_string())
                {
                    Ok(values) if !values.is_empty() => {
                        saved
                            .settings
                            .entry(owner.clone())
                            .or_default()
                            .insert(game.clone(), values);
                    }
                    Ok(_) => {}
                    Err(error) => warn!(%error, owner, game, "unreadable saved settings"),
                }
            }
            if let Ok(data) = resource.get(DATA) {
                let revision = match resource.get(DATA_REVISION) {
                    Ok(Value::Integer(n)) => (*n).max(0) as u64,
                    _ => 0,
                };
                match serde_json::from_str(&data.to_string()) {
                    Ok(data) => {
                        saved
                            .data
                            .entry(owner.clone())
                            .or_default()
                            .insert(game.clone(), SavedPlayerData { data, revision });
                    }
                    Err(error) => warn!(%error, owner, game, "unreadable saved progress"),
                }
            }
        }
        Ok(saved)
    }

    /// Replace `owner`'s settings for `game`.
    pub async fn put_settings(
        &mut self,
        owner: &str,
        game: &str,
        values: &BTreeMap<String, SettingValue>,
    ) -> Result<()> {
        let json = serde_json::to_string(values)?;
        self.put(owner, game, vec![(SETTINGS, Value::String(json))])
            .await
    }

    /// Replace `owner`'s progress for `game`.
    pub async fn put_data(
        &mut self,
        owner: &str,
        game: &str,
        saved: &SavedPlayerData,
    ) -> Result<()> {
        let json = serde_json::to_string(&saved.data)?;
        self.put(
            owner,
            game,
            vec![
                (DATA, Value::String(json)),
                (DATA_REVISION, Value::Integer(saved.revision as i64)),
            ],
        )
        .await
    }

    async fn put(&mut self, owner: &str, game: &str, props: Vec<(&str, Value)>) -> Result<()> {
        let key = (owner.to_string(), game.to_string());
        match self.records.get(&key) {
            Some(subject) => {
                let mut resource = self
                    .db
                    .get_resource(&subject.as_str().into())
                    .await
                    .map_err(atomic)?;
                for (property, value) in props {
                    resource
                        .set_unsafe(property.into(), value)
                        .map_err(atomic)?;
                }
                resource.save_locally(&self.db).await.map_err(atomic)?;
            }
            None => {
                let mut all = vec![
                    (OWNER, Value::String(owner.into())),
                    (GAME, Value::String(game.into())),
                ];
                all.extend(props);
                let subject = self
                    .db
                    .create_resource(
                        PLAYER_GAME,
                        &self.drive,
                        &format!("{owner} / {game}"),
                        Some(all),
                    )
                    .await
                    .map_err(atomic)?;
                self.records.insert(key, subject);
            }
        }
        // redb writes are not durable until flushed; a host that is killed
        // must not lose what a player just unlocked.
        self.db.flush().map_err(atomic)?;
        Ok(())
    }
}

/// Where the evening's daemon keeps its store: `GAMENIGHT_STORE`, else
/// `gamenight/store` in the user data directory.
pub fn default_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("GAMENIGHT_STORE") {
        return dir.into();
    }
    data_root().join("gamenight/store")
}

/// The user data directory the host keeps its files in.
pub fn data_root() -> PathBuf {
    std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("XDG_DATA_HOME").map(PathBuf::from))
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/share")
        })
}

enum Request {
    Settings {
        owner: String,
        game: String,
        values: BTreeMap<String, SettingValue>,
    },
    Data {
        owner: String,
        game: String,
        saved: SavedPlayerData,
    },
    Flush(oneshot::Sender<()>),
}

/// A cheap handle the synchronous daemon writes through. Writes go to a
/// background task in order; a failed write is logged and tonight's values
/// stay in memory.
#[derive(Clone)]
pub struct StoreHandle {
    tx: mpsc::UnboundedSender<Request>,
}

impl StoreHandle {
    /// Run `store` on its own task.
    pub fn spawn(mut store: Store) -> Self {
        let (tx, mut rx) = mpsc::unbounded_channel();
        tokio::spawn(async move {
            while let Some(request) = rx.recv().await {
                let result = match request {
                    Request::Settings {
                        owner,
                        game,
                        values,
                    } => store.put_settings(&owner, &game, &values).await,
                    Request::Data { owner, game, saved } => {
                        store.put_data(&owner, &game, &saved).await
                    }
                    Request::Flush(done) => {
                        let _ = done.send(());
                        Ok(())
                    }
                };
                if let Err(error) = result {
                    warn!(%error, "could not save to the player store");
                }
            }
        });
        Self { tx }
    }

    pub fn put_settings(&self, owner: &str, game: &str, values: BTreeMap<String, SettingValue>) {
        let _ = self.tx.send(Request::Settings {
            owner: owner.into(),
            game: game.into(),
            values,
        });
    }

    pub fn put_data(&self, owner: &str, game: &GameId, saved: SavedPlayerData) {
        let _ = self.tx.send(Request::Data {
            owner: owner.into(),
            game: game.0.clone(),
            saved,
        });
    }

    /// Wait until every write sent so far is done.
    pub async fn flush(&self) {
        let (done, wait) = oneshot::channel();
        if self.tx.send(Request::Flush(done)).is_ok() {
            let _ = wait.await;
        }
    }
}

/// Bring settings from the JSON file the host used before this store
/// (`gamenight/player-settings.json`) in once, then rename the file so it
/// is not read again.
pub async fn migrate_settings_file(store: &mut Store, path: &Path) -> Result<usize> {
    let Ok(bytes) = std::fs::read(path) else {
        return Ok(0);
    };
    let file: serde_json::Value = serde_json::from_slice(&bytes)?;
    let players: PlayerSettingsStore =
        serde_json::from_value(file.get("players").cloned().unwrap_or_default())?;
    let mut count = 0;
    for (owner, games) in players {
        if owner.starts_with("party:") {
            continue;
        }
        for (game, values) in games {
            store.put_settings(&owner, &game, &values).await?;
            count += 1;
        }
    }
    std::fs::rename(path, path.with_extension("json.migrated"))?;
    info!(count, path = %path.display(), "player settings moved into the store");
    Ok(count)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp() -> PathBuf {
        std::env::temp_dir().join(format!("gamenight-store-{}", uuid::Uuid::new_v4()))
    }

    #[tokio::test]
    async fn settings_and_progress_survive_a_restart() {
        let dir = temp();
        let mut values = BTreeMap::new();
        values.insert("sensitivity".to_string(), SettingValue::Number(180));
        let progress = SavedPlayerData {
            data: serde_json::json!({"spells": ["fire", "ice"]}),
            revision: 3,
        };
        let agent = {
            let mut store = Store::open(&dir).await.unwrap();
            store
                .put_settings("account:ada", "shooter", &values)
                .await
                .unwrap();
            store
                .put_data("account:ada", "spellstorm", &progress)
                .await
                .unwrap();
            // A second write to the same record edits it.
            let newer = SavedPlayerData {
                data: serde_json::json!({"spells": ["fire", "ice", "storm"]}),
                revision: 4,
            };
            store
                .put_data("account:ada", "spellstorm", &newer)
                .await
                .unwrap();
            store.agent().unwrap()
        };
        let store = Store::open(&dir).await.unwrap();
        assert_eq!(store.agent().unwrap(), agent, "the host keeps its agent");
        let saved = store.load().await.unwrap();
        assert_eq!(saved.settings["account:ada"]["shooter"], values);
        let spells = &saved.data["account:ada"]["spellstorm"];
        assert_eq!(spells.revision, 4);
        assert_eq!(spells.data["spells"][2], "storm");
        assert!(!saved.settings["account:ada"].contains_key("spellstorm"));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[tokio::test]
    async fn the_old_settings_file_moves_in_once() {
        let dir = temp();
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("player-settings.json");
        std::fs::write(
            &file,
            serde_json::to_vec(&serde_json::json!({
                "version": 1,
                "players": {"local:bo": {"ballkickers": {"character": "cat"}}}
            }))
            .unwrap(),
        )
        .unwrap();
        let mut store = Store::open(&dir.join("store")).await.unwrap();
        assert_eq!(migrate_settings_file(&mut store, &file).await.unwrap(), 1);
        assert!(!file.exists());
        assert_eq!(migrate_settings_file(&mut store, &file).await.unwrap(), 0);
        let saved = store.load().await.unwrap();
        assert_eq!(
            saved.settings["local:bo"]["ballkickers"]["character"],
            SettingValue::Choice("cat".into())
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    #[tokio::test]
    async fn the_handle_writes_in_order() {
        let dir = temp();
        let handle = StoreHandle::spawn(Store::open(&dir).await.unwrap());
        for revision in 1..=5 {
            handle.put_data(
                "local:cy",
                &GameId::new("hexstead"),
                SavedPlayerData {
                    data: serde_json::json!({ "round": revision }),
                    revision,
                },
            );
        }
        handle.flush().await;
        drop(handle);
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        let saved = Store::open(&dir).await.unwrap().load().await.unwrap();
        assert_eq!(saved.data["local:cy"]["hexstead"].revision, 5);
        let _ = std::fs::remove_dir_all(dir);
    }
}
