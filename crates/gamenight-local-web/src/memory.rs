//! Opt-in player memory for one desktop installation. Never stores phone/account tokens.
use crate::Profile;
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, path::PathBuf};
#[derive(Clone, Default, Serialize, Deserialize)]
pub struct Memory {
    pub device: String,
    pub profiles: HashMap<String, Profile>,
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
        }
        next.save()?;
        *self = next;
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
