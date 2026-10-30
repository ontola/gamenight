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

pub mod projects;
pub mod schema;
pub mod sync;

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::time::Duration;

use atomic_lib::db::trees::Tree;
use atomic_lib::{Db, Resource, Storelike, Value};
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
    /// Profiles whose records live in their account's drive on a hub
    /// instead of this device's own drive: owner -> drive.
    linked: BTreeMap<String, String>,
    /// (owner, game) -> subject of its resource.
    records: HashMap<(String, String), String>,
    /// The hub's schema drive, once an account drive pointed to it.
    schema_drive: Option<String>,
    /// Games with a published save schema: game -> fields.
    schemas: HashMap<String, schema::Fields>,
    /// When the schema drive was last synced.
    schemas_synced: Option<std::time::Instant>,
}

/// Where the owner -> drive links are kept, in the database's own key-value
/// tree.
const LINKS_KEY: &[u8] = b"gamenight:linked-drives";
/// And the hub's schema drive.
const SCHEMA_DRIVE_KEY: &[u8] = b"gamenight:schema-drive";
/// How often the schema drive is synced at most: schemas change with a
/// game's release, not during play.
const SCHEMAS_EVERY: Duration = Duration::from_secs(600);

impl Store {
    /// Open the store in `dir`, creating the database, agent and drive the
    /// first time.
    pub async fn open(dir: &Path) -> Result<Self> {
        std::fs::create_dir_all(dir)?;
        let secret_path = dir.join("agent.secret");
        // A store closed a moment ago may still be held by atomic_lib's own
        // background work for a little while.
        let mut tries = 0;
        let db = loop {
            match Db::init_redb_file(dir, None, &dir.join("uploads")).await {
                Ok(db) => break db,
                Err(error) if tries < 50 && error.to_string().contains("already open") => {
                    tries += 1;
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
                Err(error) => return Err(atomic(error)),
            }
        };
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
        let linked = db
            .kv
            .get(Tree::PluginMeta, LINKS_KEY)
            .ok()
            .flatten()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        let schema_drive = db
            .kv
            .get(Tree::PluginMeta, SCHEMA_DRIVE_KEY)
            .ok()
            .flatten()
            .and_then(|bytes| String::from_utf8(bytes.to_vec()).ok());
        let schemas = match &schema_drive {
            Some(drive) => schema::load(&db, drive).await?,
            None => HashMap::new(),
        };
        let mut store = Self {
            db,
            drive,
            linked,
            records: HashMap::new(),
            schema_drive,
            schemas,
            schemas_synced: None,
        };
        store.scan(&store.drive.clone()).await?;
        for drive in store.linked.values().cloned().collect::<BTreeSet<_>>() {
            store.scan(&drive).await?;
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

    /// The full agent, to sign sync sessions with.
    pub fn signer(&self) -> Result<atomic_lib::agents::Agent> {
        self.db.get_default_agent().map_err(atomic)
    }

    /// The account drive `owner`'s records live in, once linked.
    pub fn linked_drive(&self, owner: &str) -> Option<&str> {
        self.linked.get(owner).map(String::as_str)
    }

    /// Every owner -> drive link.
    pub fn links(&self) -> &BTreeMap<String, String> {
        &self.linked
    }

    /// Take note of `drive`'s PlayerGame records. Where a drive holds two
    /// records for one profile and game (made on two devices before either
    /// had synced), the one with the most progress is used from then on.
    async fn scan(&mut self, drive: &str) -> Result<Vec<(String, String)>> {
        let mut found: Vec<(String, String)> = Vec::new();
        for resource in self
            .db
            .get_children(drive, Some(PLAYER_GAME))
            .await
            .map_err(atomic)?
        {
            let (Ok(owner), Ok(game)) = (resource.get(OWNER), resource.get(GAME)) else {
                continue;
            };
            let key = (owner.to_string(), game.to_string());
            let subject = resource.get_subject().to_string();
            let better = match self.records.get(&key) {
                Some(current) if *current != subject => {
                    let current = self.db.get_resource(&current.as_str().into()).await.ok();
                    let theirs = current.as_ref().map(revision).unwrap_or(-1);
                    (revision(&resource), std::cmp::Reverse(subject.clone()))
                        > (theirs, std::cmp::Reverse(self.records[&key].clone()))
                }
                Some(_) => false,
                None => true,
            };
            if better {
                self.records.insert(key.clone(), subject);
            }
            found.push(key);
        }
        Ok(found)
    }

    /// Keep `owner`'s records in `drive` (their account's drive on a hub)
    /// from now on. Call after a first sync of that drive, so what the
    /// account already has is here. Records this device kept on its own
    /// drive move over; where the account has the same game too, the one
    /// with the most progress wins and missing settings are filled in.
    pub async fn link(&mut self, owner: &str, drive: &str) -> Result<()> {
        self.link_from(owner, owner, drive).await
    }

    /// [`Store::link`], taking over the records this device kept as `from`
    /// (the phone keeps its own player as `me` until it signs in).
    pub async fn link_from(&mut self, from: &str, owner: &str, drive: &str) -> Result<()> {
        if from == owner && self.linked.get(owner).map(String::as_str) == Some(drive) {
            return Ok(());
        }
        let local: Vec<(String, String)> = self
            .records
            .iter()
            .filter(|((o, _), _)| o == from)
            .map(|((_, game), subject)| (game.clone(), subject.clone()))
            .collect();
        self.linked.insert(owner.to_string(), drive.to_string());
        self.save_links()?;
        for (game, _) in &local {
            self.records.remove(&(from.to_string(), game.clone()));
        }
        self.scan(drive).await?;
        for (game, subject) in local {
            let mut old = self
                .db
                .get_resource(&subject.as_str().into())
                .await
                .map_err(atomic)?;
            let key = (owner.to_string(), game.clone());
            let mut props = Vec::new();
            let theirs = match self.records.get(&key) {
                Some(s) => Some(
                    self.db
                        .get_resource(&s.as_str().into())
                        .await
                        .map_err(atomic)?,
                ),
                None => None,
            };
            if theirs.as_ref().map(revision).unwrap_or(-1) < revision(&old) {
                for (property, value) in old.get_propvals() {
                    if property == DATA || property == DATA_REVISION || schema::is_field(property) {
                        props.push((property.to_string(), Some(value.clone())));
                    }
                }
            }
            if let Ok(mine) = old.get(SETTINGS) {
                let mut merged: serde_json::Map<String, serde_json::Value> =
                    serde_json::from_str(&mine.to_string()).unwrap_or_default();
                if let Some(Ok(account)) = theirs.as_ref().map(|r| r.get(SETTINGS)) {
                    let account: serde_json::Map<String, serde_json::Value> =
                        serde_json::from_str(&account.to_string()).unwrap_or_default();
                    merged.extend(account);
                }
                props.push((
                    SETTINGS.into(),
                    Some(Value::String(serde_json::to_string(&merged)?)),
                ));
            }
            if !props.is_empty() {
                self.put(owner, &game, props).await?;
            }
            if subject_drive_is(&old, &self.drive) {
                old.destroy(&self.db).await.map_err(atomic)?;
            }
        }
        self.db.flush().map_err(atomic)?;
        Ok(())
    }

    /// Stop keeping `owner`'s records in an account drive: new writes go to
    /// this device's own drive again. What was synced stays readable here
    /// until the drive is gone.
    pub async fn unlink(&mut self, owner: &str) -> Result<()> {
        if self.linked.remove(owner).is_some() {
            self.save_links()?;
        }
        Ok(())
    }

    fn save_links(&self) -> Result<()> {
        self.db
            .kv
            .insert(
                Tree::PluginMeta,
                LINKS_KEY,
                &serde_json::to_vec(&self.linked)?,
            )
            .map_err(atomic)?;
        self.db.flush().map_err(atomic)?;
        Ok(())
    }

    /// Sync `owner`'s account drive with the hub at the other end of
    /// `transport`, and return the games whose records changed.
    pub async fn sync<T: atomic_lib::sync::transport::AtomicTransport>(
        &mut self,
        transport: &mut T,
        origin: &str,
        drive: &str,
    ) -> Result<(sync::SyncReport, Vec<(String, String)>)> {
        let agent = self.signer()?;
        let report = sync::sync_drive(&self.db, &agent, transport, origin, drive).await?;
        let changed = if report.received > 0 {
            self.scan(drive).await?
        } else {
            Vec::new()
        };
        if self.schema_drive.is_none() {
            if let Some(schemas) = schema::schema_drive_of(&self.db, drive).await {
                self.db
                    .kv
                    .insert(Tree::PluginMeta, SCHEMA_DRIVE_KEY, schemas.as_bytes())
                    .map_err(atomic)?;
                self.db.flush().map_err(atomic)?;
                self.schema_drive = Some(schemas);
            }
        }
        Ok((report, changed))
    }

    /// The schema drive to sync now, if one is known and it is due.
    pub fn schemas_due(&self) -> Option<&str> {
        let due = self
            .schemas_synced
            .is_none_or(|at| at.elapsed() >= SCHEMAS_EVERY);
        self.schema_drive.as_deref().filter(|_| due)
    }

    /// Sync the hub's schema drive (read only), and return every record
    /// when a schema changed, since that changes how their data reads.
    pub async fn sync_schemas<T: atomic_lib::sync::transport::AtomicTransport>(
        &mut self,
        transport: &mut T,
        origin: &str,
    ) -> Result<(sync::SyncReport, Vec<(String, String)>)> {
        let Some(drive) = self.schema_drive.clone() else {
            return Ok((sync::SyncReport::default(), Vec::new()));
        };
        let agent = self.signer()?;
        let report = sync::sync_drive(&self.db, &agent, transport, origin, &drive).await?;
        self.schemas_synced = Some(std::time::Instant::now());
        let mut changed = Vec::new();
        if report.received > 0 {
            let schemas = schema::load(&self.db, &drive).await?;
            if schemas != self.schemas {
                self.schemas = schemas;
                changed = self.records.keys().cloned().collect();
            }
        }
        Ok((report, changed))
    }

    /// Sync `drive` with the hub at `url` (`wss://host/atomic/ws`), and the
    /// hub's schema drive when it is due. Returns what was sent and
    /// received, and the records that changed.
    pub async fn sync_hub(
        &mut self,
        url: &str,
        drive: &str,
    ) -> Result<(sync::SyncReport, Vec<(String, String)>)> {
        let origin = sync::origin_of(url);
        let mut transport = sync::WsTransport::connect(url).await?;
        let (mut report, mut changed) = self.sync(&mut transport, &origin, drive).await?;
        if self.schemas_due().is_some() {
            let mut transport = sync::WsTransport::connect(url).await?;
            match self.sync_schemas(&mut transport, &origin).await {
                Ok((schemas, more)) => {
                    report.received += schemas.received;
                    changed.extend(more);
                }
                Err(error) => warn!(%error, "could not sync the save schemas"),
            }
        }
        Ok((report, changed))
    }

    /// The fields of `game`'s published save schema, if it has one here.
    pub fn schema(&self, game: &str) -> Option<&schema::Fields> {
        self.schemas.get(game)
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
            let blob = match resource.get(DATA) {
                Ok(data) => match serde_json::from_str(&data.to_string()) {
                    Ok(data) => Some(data),
                    Err(error) => {
                        warn!(%error, owner, game, "unreadable saved progress");
                        None
                    }
                },
                Err(_) => None,
            };
            let data = match self.schemas.get(game) {
                Some(fields) => schema::join(&resource, blob, fields),
                None => blob,
            };
            if let Some(data) = data {
                let revision = match resource.get(DATA_REVISION) {
                    Ok(Value::Integer(n)) => (*n).max(0) as u64,
                    _ => 0,
                };
                saved
                    .data
                    .entry(owner.clone())
                    .or_default()
                    .insert(game.clone(), SavedPlayerData { data, revision });
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
        self.put(
            owner,
            game,
            vec![(SETTINGS.into(), Some(Value::String(json)))],
        )
        .await
    }

    /// Replace `owner`'s progress for `game`.
    pub async fn put_data(
        &mut self,
        owner: &str,
        game: &str,
        saved: &SavedPlayerData,
    ) -> Result<()> {
        let mut props: Vec<(String, Option<Value>)> = Vec::new();
        let blob = match self.schemas.get(game) {
            Some(fields) => {
                let (typed, rest) = schema::split(&saved.data, fields);
                // A field the game left out this time is gone, as it would
                // be from the blob; so is the old end of a renamed field.
                for field in fields.values() {
                    if !typed.iter().any(|(p, _)| *p == field.property) {
                        props.push((field.property.clone(), None));
                    }
                }
                for stale in schema::superseded(&self.db, &typed) {
                    props.push((stale, None));
                }
                props.extend(typed.into_iter().map(|(p, v)| (p, Some(v))));
                rest
            }
            None => saved.data.clone(),
        };
        props.push((
            DATA.into(),
            Some(Value::String(serde_json::to_string(&blob)?)),
        ));
        props.push((
            DATA_REVISION.into(),
            Some(Value::Integer(saved.revision as i64)),
        ));
        self.put(owner, game, props).await
    }

    /// Set (or, for `None`, remove) these properties of `owner`'s record
    /// for `game`, creating it the first time.
    async fn put(
        &mut self,
        owner: &str,
        game: &str,
        props: Vec<(String, Option<Value>)>,
    ) -> Result<()> {
        let key = (owner.to_string(), game.to_string());
        match self.records.get(&key) {
            Some(subject) => {
                let mut resource = self
                    .db
                    .get_resource(&subject.as_str().into())
                    .await
                    .map_err(atomic)?;
                for (property, value) in props {
                    match value {
                        Some(value) => {
                            resource.set_unsafe(property, value).map_err(atomic)?;
                        }
                        None => {
                            if resource.get(&property).is_ok() {
                                resource.remove_propval(&property).map_err(atomic)?;
                            }
                        }
                    }
                }
                resource.save_locally(&self.db).await.map_err(atomic)?;
            }
            None => {
                let mut all = vec![
                    (OWNER, Value::String(owner.into())),
                    (GAME, Value::String(game.into())),
                ];
                all.extend(
                    props
                        .iter()
                        .filter_map(|(p, v)| v.clone().map(|v| (p.as_str(), v))),
                );
                let subject = self
                    .db
                    .create_resource(
                        PLAYER_GAME,
                        self.linked.get(owner).unwrap_or(&self.drive),
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

/// How much progress a record holds, to choose between two of them.
fn revision(resource: &Resource) -> i64 {
    match resource.get(DATA_REVISION) {
        Ok(Value::Integer(n)) => *n,
        _ => 0,
    }
}

fn subject_drive_is(resource: &Resource, drive: &str) -> bool {
    resource
        .get(atomic_lib::urls::PARENT)
        .map(|p| p.to_string() == drive)
        .unwrap_or(false)
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
    Hub {
        url: String,
        drives: BTreeMap<String, String>,
    },
    Projects(ProjectsWatch),
    /// The folders of the games installed here, by game id, that a new mod
    /// of one can be copied from.
    ProjectBases(BTreeMap<String, PathBuf>),
    Flush(oneshot::Sender<()>),
}

/// Players' projects on this host: the folders to keep in their drives,
/// and where to write out the projects of everyone seated here to run them.
struct ProjectsWatch {
    /// `projects.json`: `[{"dir": "...", "profile": "account:<id>"}]`.
    file: PathBuf,
    cache: PathBuf,
    tx: mpsc::UnboundedSender<Vec<ShelfProject>>,
    last: Option<Vec<ShelfProject>>,
    bases: BTreeMap<String, PathBuf>,
}

/// A project of someone seated here, written out and ready to run.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ShelfProject {
    pub owner: String,
    pub id: String,
    pub title: String,
    pub dir: PathBuf,
    /// For a mod: the game it was made from.
    pub base: Option<String>,
}

#[derive(serde::Deserialize)]
struct WatchedFolder {
    dir: PathBuf,
    profile: String,
}

/// How often watched project folders are checked for edits.
const PROJECTS_EVERY: Duration = Duration::from_secs(2);

/// A sync soon after a save, so a few saves in a row go out together.
const SYNC_AFTER_SAVE: Duration = Duration::from_secs(2);
/// And now and then, for what changed elsewhere (a setting changed on the
/// phone).
const SYNC_EVERY: Duration = Duration::from_secs(60);

/// A cheap handle the synchronous daemon writes through. Writes go to a
/// background task in order; a failed write is logged and tonight's values
/// stay in memory.
#[derive(Clone)]
pub struct StoreHandle {
    tx: mpsc::UnboundedSender<Request>,
}

/// The background task: writes in order, and syncs the account drives the
/// cloud handed over with their hub.
struct Worker {
    store: Store,
    /// The hub's WebSocket URL and the owner -> drive the cloud says this
    /// host may sync right now.
    hub: Option<(String, BTreeMap<String, String>)>,
    /// Owners saved since their last sync.
    dirty: BTreeSet<String>,
    /// Saved records that changed through a sync, for the night to take in.
    updates: Option<mpsc::UnboundedSender<Saved>>,
    projects: Option<ProjectsWatch>,
}

impl Worker {
    async fn handle(&mut self, request: Request) -> Result<()> {
        match request {
            Request::Settings {
                owner,
                game,
                values,
            } => {
                self.store.put_settings(&owner, &game, &values).await?;
                self.dirty.insert(owner);
            }
            Request::Data { owner, game, saved } => {
                self.store.put_data(&owner, &game, &saved).await?;
                self.dirty.insert(owner);
            }
            Request::Hub { url, drives } => {
                let new: Vec<(String, String)> = drives
                    .iter()
                    .filter(|(owner, drive)| self.store.linked_drive(owner) != Some(drive.as_str()))
                    .map(|(o, d)| (o.clone(), d.clone()))
                    .collect();
                self.hub = Some((url, drives));
                for (owner, drive) in new {
                    // Take what the account already has, then move this
                    // host's records for it over.
                    self.sync(&owner, &drive).await?;
                    self.store.link(&owner, &drive).await?;
                    self.emit([owner.clone()].into()).await?;
                    self.dirty.insert(owner);
                }
                self.refresh_projects().await?;
            }
            Request::Projects(watch) => {
                self.projects = Some(watch);
                self.save_projects().await;
                self.refresh_projects().await?;
            }
            Request::ProjectBases(bases) => {
                if let Some(watch) = &mut self.projects {
                    if watch.bases != bases {
                        watch.bases = bases;
                        self.refresh_projects().await?;
                    }
                }
            }
            Request::Flush(done) => {
                let _ = done.send(());
            }
        }
        Ok(())
    }

    /// Sync one account drive, and pass on what changed.
    async fn sync(&mut self, owner: &str, drive: &str) -> Result<()> {
        if self.hub.is_none() {
            return Ok(());
        }
        // What was changed in a running project goes up before what came in
        // elsewhere is written over it.
        self.save_shelf().await;
        let (url, _) = self.hub.as_ref().unwrap();
        let (report, changed) = self.store.sync_hub(url, drive).await?;
        info!(
            owner,
            sent = report.sent,
            received = report.received,
            "player store synced"
        );
        self.emit(changed.into_iter().map(|(o, _)| o).collect())
            .await?;
        if report.received > 0 {
            self.refresh_projects().await?;
        }
        Ok(())
    }

    /// Keep each watched folder whose profile is seated here (its account
    /// drive linked) as that profile's project.
    async fn save_projects(&mut self) {
        let Some(watch) = &self.projects else {
            return;
        };
        let folders: Vec<WatchedFolder> = match std::fs::read(&watch.file) {
            Ok(bytes) => match serde_json::from_slice(&bytes) {
                Ok(folders) => folders,
                Err(error) => {
                    warn!(%error, file = %watch.file.display(), "unreadable projects file");
                    return;
                }
            },
            Err(_) => return,
        };
        for folder in folders {
            let seated = self
                .hub
                .as_ref()
                .is_some_and(|(_, drives)| drives.contains_key(&folder.profile));
            if !seated || self.store.linked_drive(&folder.profile).is_none() {
                continue;
            }
            match self.store.save_project(&folder.profile, &folder.dir).await {
                Ok((project, changed)) if changed > 0 => {
                    info!(
                        project = project.id,
                        changed, "project saved to the player's drive"
                    );
                    self.dirty.insert(folder.profile);
                }
                Ok(_) => {}
                Err(error) => {
                    warn!(%error, dir = %folder.dir.display(), "could not save the project")
                }
            }
        }
    }

    /// Keep what changed in the written-out projects (a mod Claude edits while
    /// it runs) in their owners' drives.
    async fn save_shelf(&mut self) {
        let Some(shelf) = self.projects.as_ref().and_then(|w| w.last.clone()) else {
            return;
        };
        for project in shelf {
            if self.store.linked_drive(&project.owner).is_none() || !project.dir.is_dir() {
                continue;
            }
            match self.store.save_project(&project.owner, &project.dir).await {
                Ok((_, changed)) if changed > 0 => {
                    info!(project = project.id, changed, "changes to a running project saved");
                    self.dirty.insert(project.owner);
                }
                Ok(_) => {}
                Err(error) => warn!(%error, project = project.id, "could not save the project"),
            }
        }
    }

    /// Write out the projects of everyone seated here, and tell the daemon
    /// when the list changed. A running project picks up the rewritten files
    /// with Warp's hot reload.
    async fn refresh_projects(&mut self) -> Result<()> {
        let Some(watch) = &self.projects else {
            return Ok(());
        };
        let owners: Vec<String> = match &self.hub {
            Some((_, drives)) => drives
                .keys()
                .filter(|o| self.store.linked_drive(o).is_some())
                .cloned()
                .collect(),
            None => Vec::new(),
        };
        let mut shelf = Vec::new();
        for owner in owners {
            let folder: String = owner
                .chars()
                .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
                .collect();
            for project in self.store.projects(&owner).await? {
                if let Some(base) = &project.base {
                    // A new mod: a copy of its game, if that is installed here.
                    if let Some(from) = watch.bases.get(base) {
                        match self.store.fill_mod(&owner, &project.id, from).await {
                            Ok(0) => {}
                            Ok(files) => {
                                info!(project = project.id, base, files, "new mod made from its game");
                                self.dirty.insert(owner.clone());
                            }
                            Err(error) => warn!(%error, project = project.id, "could not make the mod"),
                        }
                    }
                    if !self.store.has_files(&project.subject).await? {
                        continue;
                    }
                }
                let dir = watch.cache.join(&folder).join(&project.id);
                let changed = self.store.write_project(&owner, &project.id, &dir).await?;
                if changed > 0 {
                    info!(project = project.id, changed, "project files written out");
                }
                shelf.push(ShelfProject {
                    owner: owner.clone(),
                    id: project.id,
                    title: project.title,
                    dir,
                    base: project.base,
                });
            }
        }
        let watch = self.projects.as_mut().unwrap();
        if watch.last.as_ref() != Some(&shelf) {
            let _ = watch.tx.send(shelf.clone());
            watch.last = Some(shelf);
        }
        Ok(())
    }

    /// Hand the night what is saved now for `owners`.
    async fn emit(&self, owners: BTreeSet<String>) -> Result<()> {
        let Some(updates) = &self.updates else {
            return Ok(());
        };
        if owners.is_empty() {
            return Ok(());
        }
        let all = self.store.load().await?;
        let _ = updates.send(Saved {
            settings: all
                .settings
                .into_iter()
                .filter(|(o, _)| owners.contains(o))
                .collect(),
            data: all
                .data
                .into_iter()
                .filter(|(o, _)| owners.contains(o))
                .collect(),
        });
        Ok(())
    }

    /// Sync `owners` (all the cloud granted when `None`) that live in a drive.
    async fn sync_owners(&mut self, owners: Option<BTreeSet<String>>) {
        let Some((_, drives)) = &self.hub else {
            return;
        };
        let due: Vec<(String, String)> = drives
            .iter()
            .filter(|(owner, _)| owners.as_ref().is_none_or(|o| o.contains(*owner)))
            .filter(|(owner, drive)| self.store.linked_drive(owner) == Some(drive.as_str()))
            .map(|(o, d)| (o.clone(), d.clone()))
            .collect();
        for (owner, drive) in due {
            if let Err(error) = self.sync(&owner, &drive).await {
                warn!(%error, owner, "could not sync the player store");
                // Try again with the next round.
                self.dirty.insert(owner);
            }
        }
    }
}

impl StoreHandle {
    /// Run `store` on its own task.
    pub fn spawn(store: Store) -> Self {
        Self::start(store, None)
    }

    /// [`StoreHandle::spawn`], also handing back what a sync brought in.
    pub fn spawn_with_updates(store: Store) -> (Self, mpsc::UnboundedReceiver<Saved>) {
        let (updates, receive) = mpsc::unbounded_channel();
        (Self::start(store, Some(updates)), receive)
    }

    fn start(store: Store, updates: Option<mpsc::UnboundedSender<Saved>>) -> Self {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let mut worker = Worker {
            store,
            hub: None,
            dirty: BTreeSet::new(),
            updates,
            projects: None,
        };
        tokio::spawn(async move {
            let mut next_round = tokio::time::Instant::now() + SYNC_EVERY;
            let mut project_tick = tokio::time::interval(PROJECTS_EVERY);
            // When the first save since the last sync goes out; fixed, so
            // other wake-ups (the project tick) do not keep moving it.
            let mut due: Option<tokio::time::Instant> = None;
            loop {
                if worker.dirty.is_empty() || worker.hub.is_none() {
                    due = None;
                } else if due.is_none() {
                    due = Some(tokio::time::Instant::now() + SYNC_AFTER_SAVE);
                }
                let soon = due.map_or(next_round, |due| next_round.min(due));
                tokio::select! {
                    request = rx.recv() => {
                        let Some(request) = request else { break };
                        if let Err(error) = worker.handle(request).await {
                            warn!(%error, "could not save to the player store");
                        }
                    }
                    _ = project_tick.tick(), if worker.projects.is_some() => {
                        worker.save_projects().await;
                        worker.save_shelf().await;
                    }
                    _ = tokio::time::sleep_until(soon) => {
                        if tokio::time::Instant::now() >= next_round {
                            worker.dirty.clear();
                            worker.sync_owners(None).await;
                            next_round = tokio::time::Instant::now() + SYNC_EVERY;
                        } else {
                            let owners = std::mem::take(&mut worker.dirty);
                            worker.sync_owners(Some(owners)).await;
                        }
                        due = None;
                    }
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

    /// Sync these profiles' records (owner -> account drive) with the hub
    /// at `url` (`wss://host/atomic/ws`), as the cloud allows right now.
    pub fn sync_with(&self, url: &str, drives: BTreeMap<String, String>) {
        let _ = self.tx.send(Request::Hub {
            url: url.into(),
            drives,
        });
    }

    /// Keep the folders listed in `file` (`[{"dir", "profile"}]`) in their
    /// profiles' drives while those profiles are seated here, and write the
    /// projects of everyone seated here out under `cache`. The receiver gets
    /// the list of written-out projects whenever it changes.
    pub fn follow_projects(
        &self,
        file: PathBuf,
        cache: PathBuf,
    ) -> mpsc::UnboundedReceiver<Vec<ShelfProject>> {
        let (tx, rx) = mpsc::unbounded_channel();
        let _ = self.tx.send(Request::Projects(ProjectsWatch {
            file,
            cache,
            tx,
            last: None,
            bases: BTreeMap::new(),
        }));
        rx
    }

    /// The folders of the Warp games installed here (game id -> folder), for
    /// new mods to be copied from.
    pub fn project_bases(&self, bases: BTreeMap<String, PathBuf>) {
        let _ = self.tx.send(Request::ProjectBases(bases));
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

    #[tokio::test]
    async fn progress_follows_the_account_between_devices() {
        use crate::sync::tests::{account_drive, serve};
        let hub = Db::init_temp("hub-store").await.unwrap();
        hub.setup("Hub").await.unwrap();
        let (phone_dir, host_dir) = (temp(), temp());
        let mut phone = Store::open(&phone_dir).await.unwrap();
        let mut host = Store::open(&host_dir).await.unwrap();
        // Before signing in, the host already saved some progress for Ada.
        let early = SavedPlayerData {
            data: serde_json::json!({"level": 2}),
            revision: 2,
        };
        host.put_data("account:ada", "spellstorm", &early)
            .await
            .unwrap();
        let drive = account_drive(&hub, &[&phone.agent().unwrap(), &host.agent().unwrap()]).await;
        let origin = "https://hub.test";

        for store in [&mut phone, &mut host] {
            store
                .sync(&mut serve(hub.clone()), origin, &drive)
                .await
                .unwrap();
            store.link("account:ada", &drive).await.unwrap();
            store
                .sync(&mut serve(hub.clone()), origin, &drive)
                .await
                .unwrap();
        }
        let (_, changed) = phone
            .sync(&mut serve(hub.clone()), origin, &drive)
            .await
            .unwrap();
        assert!(changed.contains(&("account:ada".into(), "spellstorm".into())));
        let saved = phone.load().await.unwrap();
        assert_eq!(saved.data["account:ada"]["spellstorm"], early);

        // The phone changes a setting; the host gets it after a sync, and
        // still has it after a restart.
        let mut values = BTreeMap::new();
        values.insert("hand".to_string(), SettingValue::Choice("left".into()));
        phone
            .put_settings("account:ada", "spellstorm", &values)
            .await
            .unwrap();
        phone
            .sync(&mut serve(hub.clone()), origin, &drive)
            .await
            .unwrap();
        host.sync(&mut serve(hub.clone()), origin, &drive)
            .await
            .unwrap();
        drop(host);
        let host = Store::open(&host_dir).await.unwrap();
        let saved = host.load().await.unwrap();
        assert_eq!(saved.settings["account:ada"]["spellstorm"], values);
        assert_eq!(saved.data["account:ada"]["spellstorm"], early);
        assert_eq!(host.linked_drive("account:ada"), Some(drive.as_str()));
        let _ = std::fs::remove_dir_all(phone_dir);
        let _ = std::fs::remove_dir_all(host_dir);
    }

    #[tokio::test]
    async fn the_handle_syncs_after_a_save_and_hands_over_what_came_in() {
        use crate::sync::tests::{account_drive, serve_ws};
        let hub = Db::init_temp("hub-handle").await.unwrap();
        hub.setup("Hub").await.unwrap();
        let (phone_dir, host_dir) = (temp(), temp());
        let mut phone = Store::open(&phone_dir).await.unwrap();
        let host = Store::open(&host_dir).await.unwrap();
        let drive = account_drive(&hub, &[&phone.agent().unwrap(), &host.agent().unwrap()]).await;
        let url = serve_ws(hub.clone()).await;
        let origin = sync::origin_of(&url);

        // The phone already has progress in the account.
        phone
            .sync(
                &mut sync::WsTransport::connect(&url).await.unwrap(),
                &origin,
                &drive,
            )
            .await
            .unwrap();
        phone.link("account:ada", &drive).await.unwrap();
        let saved = SavedPlayerData {
            data: serde_json::json!({"level": 4}),
            revision: 4,
        };
        phone
            .put_data("account:ada", "spellstorm", &saved)
            .await
            .unwrap();
        phone
            .sync(
                &mut sync::WsTransport::connect(&url).await.unwrap(),
                &origin,
                &drive,
            )
            .await
            .unwrap();

        // The host is handed the drive and passes the progress on.
        let (handle, mut synced) = StoreHandle::spawn_with_updates(host);
        handle.sync_with(&url, [("account:ada".to_string(), drive.clone())].into());
        let got = tokio::time::timeout(Duration::from_secs(60), synced.recv())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(got.data["account:ada"]["spellstorm"], saved);

        // A save on the host reaches the phone without anyone asking.
        let newer = SavedPlayerData {
            data: serde_json::json!({"level": 5}),
            revision: 5,
        };
        handle.put_data("account:ada", &GameId::new("spellstorm"), newer.clone());
        let mut reached = false;
        for _ in 0..40 {
            tokio::time::sleep(Duration::from_millis(500)).await;
            phone
                .sync(
                    &mut sync::WsTransport::connect(&url).await.unwrap(),
                    &origin,
                    &drive,
                )
                .await
                .unwrap();
            if phone.load().await.unwrap().data["account:ada"]["spellstorm"] == newer {
                reached = true;
                break;
            }
        }
        assert!(reached, "the host's save never reached the phone");
        let _ = std::fs::remove_dir_all(phone_dir);
        let _ = std::fs::remove_dir_all(host_dir);
    }
}
