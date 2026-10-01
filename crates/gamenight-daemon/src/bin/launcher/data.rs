use std::{io, path::PathBuf};

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
    #[cfg(target_os = "macos")]
    let base = std::env::var_os("HOME").map(|home| {
        PathBuf::from(home)
            .join("Library/Application Support")
            .into_os_string()
    });
    #[cfg(not(any(windows, target_os = "macos")))]
    let base = std::env::var_os("XDG_DATA_HOME").or_else(|| {
        std::env::var_os("HOME")
            .map(|home| PathBuf::from(home).join(".local/share").into_os_string())
    });
    base.map(|base| PathBuf::from(base).join("GameNight"))
        .ok_or_else(|| io::Error::other("Cannot locate the user data directory"))
}

/// User-owned registrations survive regeneration of the launcher's shelf.
/// Downloaded catalogue games still fill gaps after this local overlay.
pub fn merge_local_games(
    shelf: &mut serde_json::Value,
    directory: &std::path::Path,
) -> io::Result<()> {
    let path = directory.join("local-games.json");
    if !path.exists() {
        return Ok(());
    }
    let games = gamenight_daemon::load_library(&path.to_string_lossy())?;
    let entries = shelf
        .as_array_mut()
        .ok_or_else(|| io::Error::other("Shelf must be an array"))?;
    for game in games {
        let value = serde_json::to_value(&game).map_err(io::Error::other)?;
        let id = value["id"].as_str().unwrap_or_default();
        if id.is_empty() || id == "lobby" {
            continue;
        }
        let Some(launch) = &game.launch else {
            continue;
        };
        let command = std::path::Path::new(&launch.command);
        if !command.is_absolute() || !command.is_file() {
            eprintln!("Skipping unavailable local game: {id}");
            continue;
        }
        if let Some(cwd) = &launch.cwd {
            if !std::path::Path::new(cwd).is_absolute() || !std::path::Path::new(cwd).is_dir() {
                continue;
            }
        }
        entries.retain(|entry| entry["id"].as_str() != Some(id));
        entries.push(value);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn local_games_survive_shelf_regeneration_without_replacing_lobby() {
        let dir =
            std::env::temp_dir().join(format!("gamenight-local-shelf-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let executable = std::env::current_exe().unwrap();
        let local = serde_json::json!([
            {"id":"ion-rush","title":"Local Ion Rush","launch":{"command":executable,"cwd":dir}},
            {"id":"lobby","title":"Invalid replacement","launch":{"command":executable}},
            {"id":"missing","title":"Unavailable","launch":{"command":"not-installed.exe"}}
        ]);
        std::fs::write(dir.join("local-games.json"), local.to_string()).unwrap();
        for _ in 0..2 {
            let mut shelf = serde_json::json!([{"id":"lobby","title":"GameNight"},{"id":"ion-rush","title":"Old build"}]);
            merge_local_games(&mut shelf, &dir).unwrap();
            assert_eq!(shelf.as_array().unwrap().len(), 2);
            assert_eq!(shelf[0]["title"], "GameNight");
            assert_eq!(shelf[1]["title"], "Local Ion Rush");
        }
        std::fs::remove_file(dir.join("local-games.json")).unwrap();
        let mut shelf = serde_json::json!([{"id":"lobby"}]);
        merge_local_games(&mut shelf, &dir).unwrap();
        assert_eq!(shelf.as_array().unwrap().len(), 1);
        std::fs::remove_dir(&dir).unwrap();
    }
}
