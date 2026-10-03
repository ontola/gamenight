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
    #[cfg(not(windows))]
    let base = std::env::var_os("XDG_DATA_HOME").or_else(|| {
        std::env::var_os("HOME")
            .map(|home| PathBuf::from(home).join(".local/share").into_os_string())
    });
    base.map(|base| PathBuf::from(base).join("GameNight"))
        .ok_or_else(|| io::Error::other("Cannot locate the user data directory"))
}
