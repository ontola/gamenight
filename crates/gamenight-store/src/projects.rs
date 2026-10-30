//! Players' own game projects: a vibecoded Warp (Luau) game folder, kept in
//! the player's drive so it goes wherever they do.
//!
//! A project is one [`PROJECT`] resource with a [`PROJECT_FILE`] child per
//! file: its path in the folder and its text. Every save is a signed commit
//! per changed file, so each file has its own history, and the project syncs
//! with the account like settings and progress. A host where the player
//! holds a seat gets their drive, lists their projects and writes one back
//! out as a folder to run it.
//!
//! Only text files a Warp game is made of are kept (Luau, WGSL, TOML, JSON,
//! Markdown), within [`MAX_FILE_BYTES`] and [`MAX_PROJECT_BYTES`]: a project
//! is code, not assets.

use std::collections::BTreeMap;
use std::path::{Component, Path, PathBuf};

use atomic_lib::{Resource, Storelike, Value};

use crate::{atomic, Result, Store};

pub const PROJECT: &str = "https://gamenight.ontola.io/ns/GameProject";
pub const PROJECT_FILE: &str = "https://gamenight.ontola.io/ns/ProjectFile";
/// On a project: its id (`id` in `game.toml`).
const PROJECT_ID: &str = "https://gamenight.ontola.io/ns/projectId";
const PROJECT_TITLE: &str = "https://gamenight.ontola.io/ns/projectTitle";
/// On a file: its path in the folder, with `/`.
const FILE_PATH: &str = "https://gamenight.ontola.io/ns/path";
const FILE_TEXT: &str = "https://gamenight.ontola.io/ns/text";
/// On a file the folder no longer has. Files are marked, not destroyed:
/// an edit syncs between devices like any other, a destroy would not.
const FILE_REMOVED: &str = "https://gamenight.ontola.io/ns/removed";
/// On a mod: the game it was made from. A host where that game is installed
/// fills a new mod with a copy of the game's own files.
const PROJECT_BASE: &str = "https://gamenight.ontola.io/ns/projectBase";
/// On a project: what was asked of it and what came of that, as JSON
/// (`[Change]`), newest last.
const PROJECT_CHANGES: &str = "https://gamenight.ontola.io/ns/projectChanges";
/// The changes a project remembers.
const MAX_CHANGES: usize = 50;

pub const MAX_FILE_BYTES: u64 = 512 * 1024;
pub const MAX_PROJECT_BYTES: u64 = 4 * 1024 * 1024;
const MAX_FILES: usize = 400;
const KINDS: &[&str] = &["luau", "lua", "wgsl", "toml", "json", "md", "txt"];

/// One of a player's projects, as a host lists them.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Project {
    pub owner: String,
    pub id: String,
    pub title: String,
    pub subject: String,
    /// For a mod: the game it was made from.
    pub base: Option<String>,
    pub changes: Vec<Change>,
}

/// One change asked of a project (a mod), and how it went.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct Change {
    /// Seconds since the Unix epoch.
    pub at: u64,
    pub asked: String,
    pub answer: String,
    pub ok: bool,
}

/// What a folder holds that a project keeps: path -> text.
pub fn read_folder(dir: &Path) -> Result<BTreeMap<String, String>> {
    let mut files = BTreeMap::new();
    let mut total = 0;
    let mut pending = vec![dir.to_path_buf()];
    while let Some(folder) = pending.pop() {
        for entry in std::fs::read_dir(&folder)? {
            let entry = entry?;
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with('.') {
                continue;
            }
            let kind = entry.file_type()?;
            if kind.is_dir() {
                pending.push(path);
                continue;
            }
            let wanted = path
                .extension()
                .and_then(|e| e.to_str())
                .is_some_and(|e| KINDS.contains(&e.to_ascii_lowercase().as_str()));
            if !kind.is_file() || !wanted {
                continue;
            }
            let size = entry.metadata()?.len();
            if size > MAX_FILE_BYTES {
                return Err(
                    format!("{} is over {} KB", path.display(), MAX_FILE_BYTES / 1024).into(),
                );
            }
            total += size;
            if total > MAX_PROJECT_BYTES || files.len() >= MAX_FILES {
                return Err(
                    format!("{} holds more code than a project keeps", dir.display()).into(),
                );
            }
            let relative = path
                .strip_prefix(dir)?
                .components()
                .map(|c| c.as_os_str().to_string_lossy().to_string())
                .collect::<Vec<_>>()
                .join("/");
            files.insert(relative, std::fs::read_to_string(&path)?);
        }
    }
    Ok(files)
}

fn removed(file: &Resource) -> bool {
    matches!(file.get(FILE_REMOVED), Ok(Value::Boolean(true)))
}

/// A stored path as a path under `dir`, or `None` when it would leave it.
fn under(dir: &Path, relative: &str) -> Option<PathBuf> {
    let path = Path::new(relative);
    let safe = !relative.is_empty() && path.components().all(|c| matches!(c, Component::Normal(_)));
    safe.then(|| dir.join(path))
}

/// `id` and `title` from a project's `game.toml`.
fn identity(files: &BTreeMap<String, String>) -> Result<(String, String)> {
    let toml = files
        .get("game.toml")
        .ok_or("A project needs a game.toml")?;
    let value = |key: &str| {
        toml.lines().find_map(|line| {
            let (k, v) = line.split_once('=')?;
            (k.trim() == key).then(|| v.trim().trim_matches('"').to_string())
        })
    };
    let id = value("id").filter(|id| is_id(id));
    let id = id.ok_or("game.toml needs an id (letters, digits, - and _)")?;
    let title = value("title").unwrap_or_else(|| id.clone());
    Ok((id, title))
}

/// `text` (a `game.toml`) with `key = "value"`: the line replaced, or added
/// at the top.
fn set_toml(text: &str, key: &str, value: &str) -> String {
    let line = format!("{key} = {}", serde_json::Value::String(value.into()));
    let mut found = false;
    let mut lines: Vec<String> = text
        .lines()
        .map(|l| match l.split_once('=') {
            Some((k, _)) if !found && k.trim() == key => {
                found = true;
                line.clone()
            }
            _ => l.to_string(),
        })
        .collect();
    if !found {
        lines.insert(0, line);
    }
    lines.join("\n") + "\n"
}

fn text_of(resource: &Resource, prop: &str) -> Option<String> {
    resource.get(prop).ok().map(|v| v.to_string())
}

fn project_of(owner: &str, resource: &Resource) -> Project {
    let text = |prop: &str| text_of(resource, prop).unwrap_or_default();
    Project {
        owner: owner.to_string(),
        id: text(PROJECT_ID),
        title: text(PROJECT_TITLE),
        subject: resource.get_subject().to_string(),
        base: text_of(resource, PROJECT_BASE).filter(|b| !b.is_empty()),
        changes: serde_json::from_str(&text(PROJECT_CHANGES)).unwrap_or_default(),
    }
}

/// Lowercase letters, digits, `-` and `_`: an id `game.toml` and the shelf take.
fn is_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 64
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

impl Store {
    async fn project_resources(&self, owner: &str) -> Result<Vec<Resource>> {
        let mut found = Vec::new();
        let mut drives = vec![self.drive.clone()];
        drives.extend(self.linked.get(owner).cloned());
        for drive in drives {
            for resource in self
                .db
                .get_children(&drive, Some(PROJECT))
                .await
                .map_err(atomic)?
            {
                if resource
                    .get(crate::OWNER)
                    .is_ok_and(|o| o.to_string() == owner)
                {
                    found.push(resource);
                }
            }
        }
        Ok(found)
    }

    /// `owner`'s projects here (in their account drive once linked), without
    /// the ones they removed.
    pub async fn projects(&self, owner: &str) -> Result<Vec<Project>> {
        let mut projects: Vec<Project> = self
            .project_resources(owner)
            .await?
            .iter()
            .filter(|r| !removed(r))
            .map(|r| project_of(owner, r))
            .collect();
        projects.sort_by(|a, b| a.title.cmp(&b.title).then(a.id.cmp(&b.id)));
        projects.dedup_by(|a, b| a.id == b.id);
        Ok(projects)
    }

    async fn project_resource(&self, owner: &str, id: &str) -> Result<Resource> {
        self.project_resources(owner)
            .await?
            .into_iter()
            .find(|r| !removed(r) && text_of(r, PROJECT_ID).as_deref() == Some(id))
            .ok_or_else(|| format!("{owner} has no project {id}").into())
    }

    /// A new, empty mod of the game `base` for `owner`, called `title`. The
    /// first host where `owner` sits that has `base` fills it with a copy of
    /// the game ([`Store::fill_mod`]).
    pub async fn new_mod(&mut self, owner: &str, base: &str, title: &str) -> Result<Project> {
        if !is_id(base) {
            return Err(format!("{base} is not a game id").into());
        }
        let title = title.trim();
        if title.is_empty() || title.len() > 80 {
            return Err("A mod needs a name of at most 80 characters".into());
        }
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let mut id = base.chars().take(40).collect::<String>();
        id += &format!("-mod-{:08x}", (nanos as u32) ^ (nanos >> 32) as u32);
        let subject = self
            .db
            .create_resource(
                PROJECT,
                self.linked.get(owner).unwrap_or(&self.drive),
                title,
                Some(vec![
                    (crate::OWNER, Value::String(owner.into())),
                    (PROJECT_ID, Value::String(id.clone())),
                    (PROJECT_TITLE, Value::String(title.into())),
                    (PROJECT_BASE, Value::String(base.into())),
                ]),
            )
            .await
            .map_err(atomic)?;
        self.db.flush().map_err(atomic)?;
        let resource = self.db.get_resource(&subject.as_str().into()).await.map_err(atomic)?;
        Ok(project_of(owner, &resource))
    }

    /// Fill `owner`'s still empty mod `id` with the files of its game, from
    /// `base_dir` (that game's folder), under the mod's own id and title.
    /// Returns how many files it got; 0 when it had files already.
    pub async fn fill_mod(&mut self, owner: &str, id: &str, base_dir: &Path) -> Result<usize> {
        let resource = self.project_resource(owner, id).await?;
        let project = project_of(owner, &resource);
        if !self.texts_of(&project.subject).await?.is_empty() {
            return Ok(0);
        }
        let mut files = read_folder(base_dir)?;
        let toml = files.get("game.toml").ok_or("The game has no game.toml")?;
        let toml = set_toml(&set_toml(toml, "id", id), "title", &project.title);
        files.insert("game.toml".into(), toml);
        let changed = self.save_files(&project.subject, &files).await?;
        self.db.flush().map_err(atomic)?;
        Ok(changed)
    }

    /// Give `owner`'s project `id` another name (in its `game.toml` too, which
    /// is where a host reads it).
    pub async fn rename_project(&mut self, owner: &str, id: &str, title: &str) -> Result<()> {
        let title = title.trim();
        if title.is_empty() || title.len() > 80 {
            return Err("A name has at most 80 characters".into());
        }
        let mut resource = self.project_resource(owner, id).await?;
        resource
            .set_unsafe(PROJECT_TITLE.into(), Value::String(title.into()))
            .map_err(atomic)?;
        resource.save_locally(&self.db).await.map_err(atomic)?;
        let subject = resource.get_subject().to_string();
        if let Some(mut toml) = self.files_of(&subject).await?.remove("game.toml") {
            let text = text_of(&toml, FILE_TEXT).unwrap_or_default();
            toml.set_unsafe(FILE_TEXT.into(), Value::String(set_toml(&text, "title", title)))
                .map_err(atomic)?;
            toml.save_locally(&self.db).await.map_err(atomic)?;
        }
        self.db.flush().map_err(atomic)?;
        Ok(())
    }

    /// Take `owner`'s project `id` off every shelf. It is marked, not
    /// destroyed, so the removal syncs like any edit.
    pub async fn remove_project(&mut self, owner: &str, id: &str) -> Result<()> {
        let mut resource = self.project_resource(owner, id).await?;
        resource
            .set_unsafe(FILE_REMOVED.into(), Value::Boolean(true))
            .map_err(atomic)?;
        resource.save_locally(&self.db).await.map_err(atomic)?;
        self.db.flush().map_err(atomic)?;
        Ok(())
    }

    /// Remember a change asked of `owner`'s project `id`.
    pub async fn note_change(&mut self, owner: &str, id: &str, change: Change) -> Result<()> {
        let mut resource = self.project_resource(owner, id).await?;
        let mut changes = project_of(owner, &resource).changes;
        changes.push(change);
        let skip = changes.len().saturating_sub(MAX_CHANGES);
        let json = serde_json::to_string(&changes[skip..])?;
        resource
            .set_unsafe(PROJECT_CHANGES.into(), Value::String(json))
            .map_err(atomic)?;
        resource.save_locally(&self.db).await.map_err(atomic)?;
        self.db.flush().map_err(atomic)?;
        Ok(())
    }

    async fn files_of(&self, project: &str) -> Result<BTreeMap<String, Resource>> {
        let mut files = BTreeMap::new();
        for file in self
            .db
            .get_children(project, Some(PROJECT_FILE))
            .await
            .map_err(atomic)?
        {
            if let Ok(path) = file.get(FILE_PATH) {
                files.insert(path.to_string(), file);
            }
        }
        Ok(files)
    }

    /// Whether the project `subject` has any files yet.
    pub(crate) async fn has_files(&self, subject: &str) -> Result<bool> {
        Ok(!self.texts_of(subject).await?.is_empty())
    }

    /// The files a project has now: path -> text.
    async fn texts_of(&self, project: &str) -> Result<BTreeMap<String, String>> {
        let mut files = BTreeMap::new();
        for (path, file) in self.files_of(project).await? {
            if !removed(&file) {
                let text = file
                    .get(FILE_TEXT)
                    .map(|v| v.to_string())
                    .unwrap_or_default();
                files.insert(path, text);
            }
        }
        Ok(files)
    }

    /// Keep the folder `dir` as `owner`'s project: new and changed files
    /// are saved, files gone from the folder are removed. Returns the
    /// project and how many files changed.
    pub async fn save_project(&mut self, owner: &str, dir: &Path) -> Result<(Project, usize)> {
        let files = read_folder(dir)?;
        let (id, title) = identity(&files)?;
        let existing = self
            .project_resources(owner)
            .await?
            .into_iter()
            .find(|r| r.get(PROJECT_ID).is_ok_and(|v| v.to_string() == id));
        let subject = match existing {
            Some(mut project) => {
                if project.get(PROJECT_TITLE).map(|v| v.to_string()).ok() != Some(title.clone()) {
                    project
                        .set_unsafe(PROJECT_TITLE.into(), Value::String(title.clone()))
                        .map_err(atomic)?;
                    project.save_locally(&self.db).await.map_err(atomic)?;
                }
                project.get_subject().to_string()
            }
            None => self
                .db
                .create_resource(
                    PROJECT,
                    self.linked.get(owner).unwrap_or(&self.drive),
                    &title,
                    Some(vec![
                        (crate::OWNER, Value::String(owner.into())),
                        (PROJECT_ID, Value::String(id.clone())),
                        (PROJECT_TITLE, Value::String(title.clone())),
                    ]),
                )
                .await
                .map_err(atomic)?,
        };
        let changed = self.save_files(&subject, &files).await?;
        self.db.flush().map_err(atomic)?;
        let resource = self.db.get_resource(&subject.as_str().into()).await.map_err(atomic)?;
        Ok((project_of(owner, &resource), changed))
    }

    /// Make the project `subject`'s files these: new and changed files are
    /// saved, files not among them are marked removed. Returns how many
    /// changed.
    async fn save_files(&mut self, subject: &str, files: &BTreeMap<String, String>) -> Result<usize> {
        let mut stored = self.files_of(subject).await?;
        let mut changed = 0;
        for (path, text) in files {
            match stored.remove(path) {
                Some(mut file) => {
                    let same =
                        file.get(FILE_TEXT).map(|v| v.to_string()).ok().as_ref() == Some(text);
                    if !same || removed(&file) {
                        file.set_unsafe(FILE_TEXT.into(), Value::String(text.clone()))
                            .map_err(atomic)?;
                        file.set_unsafe(FILE_REMOVED.into(), Value::Boolean(false))
                            .map_err(atomic)?;
                        file.save_locally(&self.db).await.map_err(atomic)?;
                        changed += 1;
                    }
                }
                None => {
                    self.db
                        .create_resource(
                            PROJECT_FILE,
                            subject,
                            path,
                            Some(vec![
                                (FILE_PATH, Value::String(path.to_string())),
                                (FILE_TEXT, Value::String(text.clone())),
                            ]),
                        )
                        .await
                        .map_err(atomic)?;
                    changed += 1;
                }
            }
        }
        for (_, mut file) in stored {
            if !removed(&file) {
                file.set_unsafe(FILE_REMOVED.into(), Value::Boolean(true))
                    .map_err(atomic)?;
                file.set_unsafe(FILE_TEXT.into(), Value::String(String::new()))
                    .map_err(atomic)?;
                file.save_locally(&self.db).await.map_err(atomic)?;
                changed += 1;
            }
        }
        Ok(changed)
    }

    /// Write `owner`'s project `id` out to `dir`, as it is stored now:
    /// changed files are rewritten (so a running `warp` hot reloads them),
    /// files the project no longer has are removed. Returns how many files
    /// changed on disk.
    pub async fn write_project(&self, owner: &str, id: &str, dir: &Path) -> Result<usize> {
        let project = self
            .projects(owner)
            .await?
            .into_iter()
            .find(|p| p.id == id)
            .ok_or_else(|| format!("{owner} has no project {id}"))?;
        std::fs::create_dir_all(dir)?;
        let mut on_disk = read_folder(dir).unwrap_or_default();
        let mut changed = 0;
        for (path, text) in self.texts_of(&project.subject).await? {
            let Some(target) = under(dir, &path) else {
                tracing::warn!(path, "project file outside its folder skipped");
                continue;
            };
            if on_disk.remove(&path).as_ref() != Some(&text) {
                if let Some(parent) = target.parent() {
                    std::fs::create_dir_all(parent)?;
                }
                let temporary = target.with_extension("gamenight-tmp");
                std::fs::write(&temporary, &text)?;
                std::fs::rename(&temporary, &target)?;
                changed += 1;
            }
        }
        for path in on_disk.keys() {
            if let Some(target) = under(dir, path) {
                let _ = std::fs::remove_file(target);
                changed += 1;
            }
        }
        Ok(changed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sync::tests::{account_drive, serve};
    use atomic_lib::Db;

    fn temp() -> PathBuf {
        std::env::temp_dir().join(format!("gamenight-project-{}", uuid::Uuid::new_v4()))
    }

    #[tokio::test]
    async fn a_project_made_at_home_plays_at_a_friends() {
        let hub = Db::init_temp("hub-projects").await.unwrap();
        hub.setup("Hub").await.unwrap();
        let (home_dir, friend_dir, folder, copy) = (temp(), temp(), temp(), temp());
        let mut home = Store::open(&home_dir).await.unwrap();
        let mut friend = Store::open(&friend_dir).await.unwrap();
        let drive = account_drive(&hub, &[&home.agent().unwrap(), &friend.agent().unwrap()]).await;
        let origin = "https://hub.test";
        for store in [&mut home, &mut friend] {
            store
                .sync(&mut serve(hub.clone()), origin, &drive)
                .await
                .unwrap();
            store.link("account:joep", &drive).await.unwrap();
        }

        std::fs::create_dir_all(folder.join("sounds")).unwrap();
        std::fs::write(
            folder.join("game.toml"),
            "title = \"Space Goats\"\nid = \"space-goats\"\n",
        )
        .unwrap();
        std::fs::write(folder.join("main.luau"), "function tick() end\n").unwrap();
        std::fs::write(folder.join("sounds/baa.luau"), "return {}\n").unwrap();
        std::fs::write(folder.join("cover.png"), [0u8; 8]).unwrap();
        let (project, changed) = home.save_project("account:joep", &folder).await.unwrap();
        assert_eq!((project.id.as_str(), changed), ("space-goats", 3));
        assert_eq!(
            home.save_project("account:joep", &folder).await.unwrap().1,
            0
        );

        home.sync(&mut serve(hub.clone()), origin, &drive)
            .await
            .unwrap();
        friend
            .sync(&mut serve(hub.clone()), origin, &drive)
            .await
            .unwrap();
        let listed = friend.projects("account:joep").await.unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].title, "Space Goats");
        assert_eq!(
            friend
                .write_project("account:joep", "space-goats", &copy)
                .await
                .unwrap(),
            3
        );
        assert_eq!(
            std::fs::read_to_string(copy.join("sounds/baa.luau")).unwrap(),
            "return {}\n"
        );
        assert!(!copy.join("cover.png").exists());

        // An edit at home reaches the friend's copy; nothing else is rewritten.
        std::fs::write(
            folder.join("main.luau"),
            "function tick() print('baa') end\n",
        )
        .unwrap();
        std::fs::remove_file(folder.join("sounds/baa.luau")).unwrap();
        assert_eq!(
            home.save_project("account:joep", &folder).await.unwrap().1,
            2
        );
        home.sync(&mut serve(hub.clone()), origin, &drive)
            .await
            .unwrap();
        friend
            .sync(&mut serve(hub.clone()), origin, &drive)
            .await
            .unwrap();
        assert_eq!(
            friend
                .write_project("account:joep", "space-goats", &copy)
                .await
                .unwrap(),
            2
        );
        assert!(std::fs::read_to_string(copy.join("main.luau"))
            .unwrap()
            .contains("baa"));
        assert!(!copy.join("sounds/baa.luau").exists());

        assert!(under(&copy, "../evil.luau").is_none() && under(&copy, "/etc/x").is_none());
        for dir in [home_dir, friend_dir, folder, copy] {
            let _ = std::fs::remove_dir_all(dir);
        }
    }
}

#[cfg(test)]
mod handle_tests {
    use super::*;
    use crate::sync::{
        self,
        tests::{account_drive, serve_ws},
    };
    use crate::StoreHandle;
    use atomic_lib::Db;
    use std::time::Duration;

    fn temp() -> PathBuf {
        std::env::temp_dir().join(format!("gamenight-project-{}", uuid::Uuid::new_v4()))
    }

    #[tokio::test]
    async fn a_watched_folder_reaches_the_shelf_of_another_host() {
        let hub = Db::init_temp("hub-project-handle").await.unwrap();
        hub.setup("Hub").await.unwrap();
        let (home_dir, friend_dir, folder, data) = (temp(), temp(), temp(), temp());
        let home = Store::open(&home_dir).await.unwrap();
        let friend = Store::open(&friend_dir).await.unwrap();
        let drive = account_drive(&hub, &[&home.agent().unwrap(), &friend.agent().unwrap()]).await;
        let url = serve_ws(hub.clone()).await;
        let drives: BTreeMap<String, String> = [("account:joep".to_string(), drive.clone())].into();

        std::fs::create_dir_all(&folder).unwrap();
        std::fs::create_dir_all(&data).unwrap();
        std::fs::write(
            folder.join("game.toml"),
            "id = \"goats\"\ntitle = \"Goats\"\n",
        )
        .unwrap();
        std::fs::write(folder.join("main.luau"), "-- v1\n").unwrap();
        let watch = data.join("projects.json");
        std::fs::write(
            &watch,
            serde_json::json!([{"dir": folder, "profile": "account:joep"}]).to_string(),
        )
        .unwrap();

        // At home: Joep is seated, the folder goes to his drive.
        let home = StoreHandle::spawn(home);
        home.sync_with(&url, drives.clone());
        let mut home_shelf = home.follow_projects(watch.clone(), data.join("home-cache"));
        let listed = tokio::time::timeout(Duration::from_secs(60), async {
            loop {
                let list = home_shelf.recv().await.unwrap();
                if !list.is_empty() {
                    break list;
                }
            }
        })
        .await
        .unwrap();
        assert_eq!(listed[0].title, "Goats");

        // At a friend's: seated there too, the project shows up written out.
        tokio::time::sleep(Duration::from_secs(5)).await;
        let friend = StoreHandle::spawn(friend);
        friend.sync_with(&url, drives);
        let mut shelf = friend.follow_projects(data.join("none.json"), data.join("friend-cache"));
        let listed = tokio::time::timeout(Duration::from_secs(60), async {
            loop {
                let list = shelf.recv().await.unwrap();
                if !list.is_empty() {
                    break list;
                }
            }
        })
        .await
        .unwrap();
        assert_eq!(
            std::fs::read_to_string(listed[0].dir.join("main.luau")).unwrap(),
            "-- v1\n"
        );
        let _ = sync::origin_of(&url);
        for dir in [home_dir, friend_dir, folder, data] {
            let _ = std::fs::remove_dir_all(dir);
        }
    }
    /// Joep makes a mod on his phone; the host he sits at has the game,
    /// fills the mod with a copy of it and puts it on the shelf; what Claude
    /// changes in it while it runs goes back to his drive, and a new name
    /// from the phone reaches the running copy.
    #[tokio::test]
    async fn a_mod_made_on_the_phone_is_filled_played_and_edited_at_the_host() {
        let hub = Db::init_temp("hub-mod").await.unwrap();
        hub.setup("Hub").await.unwrap();
        let (phone_dir, host_dir, game, data, back) = (temp(), temp(), temp(), temp(), temp());
        let mut phone = Store::open(&phone_dir).await.unwrap();
        let host = Store::open(&host_dir).await.unwrap();
        let drive = account_drive(&hub, &[&phone.agent().unwrap(), &host.agent().unwrap()]).await;
        let url = serve_ws(hub.clone()).await;
        let owner = "account:joep";
        phone.sync_hub(&url, &drive).await.unwrap();
        phone.link(owner, &drive).await.unwrap();
        let made = phone.new_mod(owner, "neon-siege-warp", "Splitting bosses").await.unwrap();
        assert!(made.id.starts_with("neon-siege-warp-mod-"));
        assert_eq!(made.base.as_deref(), Some("neon-siege-warp"));
        phone.sync_hub(&url, &drive).await.unwrap();

        std::fs::create_dir_all(game.join("sounds")).unwrap();
        std::fs::write(game.join("game.toml"), "title = \"Neon Siege\"\nid = \"neon-siege-warp\"\nplayers = 1\n").unwrap();
        std::fs::write(game.join("main.luau"), "local BOSS_SPLITS = false\n").unwrap();
        std::fs::write(game.join("sounds/boss.luau"), "return {}\n").unwrap();
        std::fs::create_dir_all(&data).unwrap();
        let host = StoreHandle::spawn(host);
        host.sync_with(&url, [(owner.to_string(), drive.clone())].into());
        let mut shelf = host.follow_projects(data.join("none.json"), data.join("cache"));
        host.project_bases([("neon-siege-warp".to_string(), game.clone())].into());
        let listed = tokio::time::timeout(Duration::from_secs(60), async {
            loop {
                let list = shelf.recv().await.unwrap();
                if !list.is_empty() {
                    break list;
                }
            }
        })
        .await
        .unwrap();
        let dir = listed[0].dir.clone();
        assert_eq!(listed[0].title, "Splitting bosses");
        assert_eq!(listed[0].base.as_deref(), Some("neon-siege-warp"));
        let toml = std::fs::read_to_string(dir.join("game.toml")).unwrap();
        assert!(toml.contains(&format!("id = \"{}\"", made.id)) && toml.contains("title = \"Splitting bosses\"") && toml.contains("players = 1"), "{toml}");
        assert_eq!(std::fs::read_to_string(dir.join("sounds/boss.luau")).unwrap(), "return {}\n");

        // Claude edits the running mod; it reaches the phone.
        std::fs::write(dir.join("main.luau"), "local BOSS_SPLITS = true\n").unwrap();
        let edited = tokio::time::timeout(Duration::from_secs(60), async {
            loop {
                tokio::time::sleep(Duration::from_millis(500)).await;
                phone.sync_hub(&url, &drive).await.unwrap();
                phone.write_project(owner, &made.id, &back).await.unwrap();
                if std::fs::read_to_string(back.join("main.luau")).is_ok_and(|t| t.contains("true")) {
                    break;
                }
            }
        })
        .await;
        assert!(edited.is_ok(), "the edit never reached the phone");

        // A new name and a change note from the phone; the running copy follows.
        phone.rename_project(owner, &made.id, "Bosses split").await.unwrap();
        phone
            .note_change(owner, &made.id, Change { at: 1, asked: "bosses split".into(), answer: "Done".into(), ok: true })
            .await
            .unwrap();
        let mods = phone.projects(owner).await.unwrap();
        assert_eq!((mods[0].title.as_str(), mods[0].changes.len()), ("Bosses split", 1));
        phone.sync_hub(&url, &drive).await.unwrap();
        host.sync_with(&url, [(owner.to_string(), drive.clone())].into());
        let renamed = tokio::time::timeout(Duration::from_secs(90), async {
            loop {
                let list = shelf.recv().await.unwrap();
                if list.first().is_some_and(|p| p.title == "Bosses split") {
                    break;
                }
            }
        })
        .await;
        assert!(renamed.is_ok(), "the new name never reached the host");
        assert!(std::fs::read_to_string(dir.join("game.toml")).unwrap().contains("title = \"Bosses split\""));
        assert!(std::fs::read_to_string(dir.join("main.luau")).unwrap().contains("true"), "the edit stays");

        // Removed on the phone: gone from the shelf.
        phone.remove_project(owner, &made.id).await.unwrap();
        assert!(phone.projects(owner).await.unwrap().is_empty());
        phone.sync_hub(&url, &drive).await.unwrap();
        host.sync_with(&url, [(owner.to_string(), drive.clone())].into());
        let gone = tokio::time::timeout(Duration::from_secs(90), async {
            loop {
                if shelf.recv().await.unwrap().is_empty() {
                    break;
                }
            }
        })
        .await;
        assert!(gone.is_ok(), "the removed mod stayed on the shelf");
        for dir in [phone_dir, host_dir, game, data, back] {
            let _ = std::fs::remove_dir_all(dir);
        }
    }
}
