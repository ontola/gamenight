//! Main player and guest memory for one installation. Never stores account tokens.
use crate::Profile;
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, path::PathBuf};
#[derive(Clone, Default, Serialize, Deserialize)]
pub struct Memory {
    pub device: String,
    pub profiles: HashMap<String, Profile>,
    #[serde(default)]
    pub main_profile: Option<String>,
    /// Once cleared, another guest must not silently become the main player.
    #[serde(default)]
    pub main_initialized: bool,
    #[serde(skip)]
    path: Option<PathBuf>,
}
impl Memory {
    pub fn load(path: PathBuf) -> std::io::Result<Self> {
        let mut memory: Self = match std::fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes)?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Self::default(),
            Err(e) => return Err(e),
        };
        memory.path = Some(path);
        if memory.device.is_empty() {
            memory.device = format!(
                "{}{}",
                uuid::Uuid::new_v4().simple(),
                uuid::Uuid::new_v4().simple()
            );
            memory.save()?;
        }
        Ok(memory)
    }
    pub fn save(&self) -> std::io::Result<()> {
        let Some(path) = &self.path else {
            return Ok(());
        };
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let temporary = path.with_extension("tmp");
        std::fs::write(&temporary, serde_json::to_vec(self)?)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&temporary, std::fs::Permissions::from_mode(0o600))?;
        }
        std::fs::rename(temporary, path)
    }
    pub fn set(&mut self, profile: &Profile, remember: bool) -> std::io::Result<()> {
        let mut next = self.clone();
        if remember {
            next.profiles.insert(profile.id.clone(), profile.clone());
        } else {
            next.profiles.remove(&profile.id);
            if next.main_profile.as_ref() == Some(&profile.id) {
                next.main_profile = None;
            }
        }
        next.save()?;
        *self = next;
        Ok(())
    }
    pub fn main_player(&mut self, profile: &Profile, enabled: bool) -> std::io::Result<()> {
        let mut next = self.clone();
        next.main_initialized = true;
        if enabled {
            next.main_profile = Some(profile.id.clone());
            next.profiles.insert(profile.id.clone(), profile.clone());
        } else if next.main_profile.as_ref() == Some(&profile.id) {
            next.main_profile = None;
            next.profiles.remove(&profile.id);
        }
        next.save()?;
        *self = next;
        Ok(())
    }
    /// Called only after a room code or controller claim has been validated.
    pub fn linked(&mut self, profile: &Profile, remember: Option<bool>) -> std::io::Result<()> {
        if !self.main_initialized {
            return self.main_player(profile, remember != Some(false));
        }
        if let Some(remember) = remember {
            self.set(profile, remember)?;
        }
        Ok(())
    }
}
pub fn path() -> PathBuf {
    if let Some(path) = std::env::var_os("GAMENIGHT_PLAYER_MEMORY") {
        return path.into();
    }
    let root = std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("XDG_DATA_HOME").map(PathBuf::from))
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/share")
        });
    root.join("gamenight/players.json")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn first_link_survives_restart_and_guests_never_replace_or_reclaim_it() {
        let dir = std::env::temp_dir().join(format!("gamenight-main-{}", uuid::Uuid::new_v4()));
        let path = dir.join("players.json");
        let profile = |id: &str| Profile {
            id: id.into(),
            username: id.into(),
            skin_color: "#abcdef".into(),
            avatar: "face-and-hat".into(),
        };
        let mut memory = Memory::load(path.clone()).unwrap();
        memory.linked(&profile("main"), None).unwrap();
        memory.linked(&profile("guest"), None).unwrap();
        let mut restored = Memory::load(path.clone()).unwrap();
        assert_eq!(restored.main_profile.as_deref(), Some("main"));
        assert_eq!(restored.profiles.len(), 1);
        assert_eq!(restored.profiles["main"].avatar, "face-and-hat");
        restored.main_player(&profile("main"), false).unwrap();
        let mut restored = Memory::load(path.clone()).unwrap();
        restored.linked(&profile("guest"), None).unwrap();
        assert!(restored.main_profile.is_none());
        assert!(restored.profiles.is_empty());
        restored.main_player(&profile("guest"), true).unwrap();
        restored.set(&profile("guest"), false).unwrap();
        assert!(Memory::load(path).unwrap().main_profile.is_none());
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn declining_first_memory_and_failed_writes_do_not_assign_main() {
        let p = Profile {
            id: "phone".into(),
            username: "Player".into(),
            skin_color: "#abcdef".into(),
            avatar: String::new(),
        };
        let mut memory = Memory::default();
        memory.linked(&p, Some(false)).unwrap();
        memory.linked(&p, None).unwrap();
        assert!(memory.main_profile.is_none());
        let blocker =
            std::env::temp_dir().join(format!("gamenight-main-file-{}", uuid::Uuid::new_v4()));
        std::fs::write(&blocker, b"not a directory").unwrap();
        memory.path = Some(blocker.join("players.json"));
        assert!(memory.main_player(&p, true).is_err());
        assert!(memory.profiles.is_empty());
        std::fs::remove_file(blocker).unwrap();
    }
    #[test]
    fn restart_restores_full_profile_and_forgetting_is_durable() {
        let dir = std::env::temp_dir().join(format!("gamenight-memory-{}", uuid::Uuid::new_v4()));
        let path = dir.join("players.json");
        let mut memory = Memory::load(path.clone()).unwrap();
        let mut profile = Profile {
            id: "phone".into(),
            username: "Joep".into(),
            skin_color: "#abcdef".into(),
            avatar: "face-and-hat".into(),
        };
        assert!(Memory::load(path.clone()).unwrap().profiles.is_empty());
        memory.set(&profile, true).unwrap();
        profile.avatar = "updated-hat".into();
        memory.set(&profile, true).unwrap();
        let mut restored = Memory::load(path.clone()).unwrap();
        assert_eq!(restored.device, memory.device);
        assert_eq!(restored.profiles["phone"].avatar, "updated-hat");
        assert_eq!(restored.profiles["phone"].skin_color, "#abcdef");
        let mut room = crate::local_room::Room::new();
        room.restore("phone");
        assert_eq!(
            room.snapshot(&restored.profiles)["pending"][0]["profile"]["display_name"],
            "Joep"
        );
        restored.set(&profile, false).unwrap();
        assert!(room.waiting("phone"));
        assert!(Memory::load(path).unwrap().profiles.is_empty());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
