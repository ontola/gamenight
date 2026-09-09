use std::{
    fs, io,
    path::{Path, PathBuf},
};

pub fn user_dir() -> io::Result<PathBuf> {
    if let Some(path) = std::env::var_os("GAMENIGHT_DATA_DIR") {
        let path = PathBuf::from(path);
        if !path.is_absolute() {
            return Err(io::Error::other("GAMENIGHT_DATA_DIR must be absolute"));
        }
        return Ok(path);
    }
    #[cfg(windows)]
    let base = std::env::var_os("LOCALAPPDATA");
    #[cfg(not(windows))]
    let base = std::env::var_os("XDG_DATA_HOME").or_else(|| {
        std::env::var_os("HOME")
            .map(|home| PathBuf::from(home).join(".local/share").into_os_string())
    });
    base.map(|base| PathBuf::from(base).join("GameNight"))
        .ok_or_else(|| io::Error::other("Cannot locate the user data directory"))
}

/// Seed immutable content once. A partial copy is never considered installed.
/// Shipping the seed also lets a fresh install start without a network connection.
pub fn seed_content(package: &Path, data: &Path, name: &str, version: &str) -> io::Result<PathBuf> {
    let parent = data.join("content").join(name);
    let destination = parent.join(version);
    if destination.join(".complete").is_file() {
        return Ok(destination);
    }
    fs::create_dir_all(&parent)?;
    let staging = parent.join(format!(".staging-{}", uuid::Uuid::new_v4()));
    let result = (|| {
        copy_tree(&package.join(name), &staging)?;
        fs::write(staging.join(".complete"), version)?;
        fs::rename(&staging, &destination)?;
        Ok(destination)
    })();
    if result.is_err() {
        let _ = fs::remove_dir_all(&staging);
    }
    result
}

fn copy_tree(source: &Path, destination: &Path) -> io::Result<()> {
    fs::create_dir_all(destination)?;
    for entry in fs::read_dir(source)? {
        let entry = entry?;
        let kind = entry.file_type()?;
        let target = destination.join(entry.file_name());
        if kind.is_dir() {
            copy_tree(&entry.path(), &target)?;
        } else if kind.is_file() {
            fs::copy(entry.path(), target)?;
        } else {
            return Err(io::Error::other(
                "Content contains a symlink or special file",
            ));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn new_app_version_keeps_content_and_user_data() {
        let temp = std::env::temp_dir().join(format!("gamenight-data-{}", uuid::Uuid::new_v4()));
        let package = temp.join("app-v1");
        let data = temp.join("user");
        fs::create_dir_all(package.join("pinpals")).unwrap();
        fs::write(package.join("pinpals/main.lua"), "first").unwrap();
        let content = seed_content(&package, &data, "pinpals", "1").unwrap();
        fs::write(data.join("settings.json"), "keep me").unwrap();
        // An update replaces the entire package directory, not the user's content.
        fs::rename(&package, temp.join("app-v2")).unwrap();
        assert_eq!(
            seed_content(&temp.join("app-v2"), &data, "pinpals", "1").unwrap(),
            content
        );
        assert_eq!(
            fs::read_to_string(data.join("settings.json")).unwrap(),
            "keep me"
        );
        fs::write(temp.join("app-v2/pinpals/main.lua"), "second").unwrap();
        let next = seed_content(&temp.join("app-v2"), &data, "pinpals", "2").unwrap();
        assert_eq!(
            fs::read_to_string(content.join("main.lua")).unwrap(),
            "first"
        );
        assert_eq!(fs::read_to_string(next.join("main.lua")).unwrap(), "second");
        fs::remove_dir_all(temp).unwrap();
    }
    #[test]
    fn failed_seed_can_be_retried() {
        let temp = std::env::temp_dir().join(format!("gamenight-data-{}", uuid::Uuid::new_v4()));
        assert!(seed_content(&temp.join("missing"), &temp, "love", "1").is_err());
        assert!(!temp.join("content/love/1/.complete").exists());
        fs::create_dir_all(temp.join("package/love")).unwrap();
        fs::write(temp.join("package/love/love.exe"), "seed").unwrap();
        assert!(seed_content(&temp.join("package"), &temp, "love", "1").is_ok());
        fs::remove_dir_all(temp).unwrap();
    }
}
