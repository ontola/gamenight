//! OS links carry catalog IDs only, never paths, commands or download URLs.
use std::{fs, io, path::Path};

pub fn game(url: &str) -> Option<&str> {
    let id = url.strip_prefix("gamenight://play/")?;
    (!id.is_empty()
        && id.len() <= 80
        && !["lobby", "demo-game"].contains(&id)
        && id.as_bytes()[0].is_ascii_alphanumeric()
        && id
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-'))
    .then_some(id)
}

pub fn request(directory: &Path, game: Option<&str>) -> io::Result<()> {
    fs::create_dir_all(directory)?;
    let temporary = directory.join(format!("catalog-request-{}.tmp", std::process::id()));
    fs::write(&temporary, serde_json::json!({"game":game}).to_string())?;
    fs::rename(temporary, directory.join("catalog-request.json"))
}

pub fn register() -> io::Result<()> {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let exe = std::env::current_exe()?;
        let command = format!("\"{}\" --open-url \"%1\"", exe.display());
        for (key, name, value) in [
            ("HKCU\\Software\\Classes\\gamenight", None, "URL:GameNight"),
            (
                "HKCU\\Software\\Classes\\gamenight",
                Some("URL Protocol"),
                "",
            ),
            (
                "HKCU\\Software\\Classes\\gamenight\\shell\\open\\command",
                None,
                command.as_str(),
            ),
        ] {
            let mut cmd = std::process::Command::new("reg.exe");
            cmd.args(["add", key]);
            if let Some(name) = name {
                cmd.args(["/v", name]);
            } else {
                cmd.arg("/ve");
            }
            if !cmd
                .args(["/t", "REG_SZ", "/d", value, "/f"])
                .creation_flags(0x08000000)
                .stdout(std::process::Stdio::null())
                .status()?
                .success()
            {
                return Err(io::Error::other("Could not register GameNight links"));
            }
        }
    }
    #[cfg(target_os = "macos")]
    {
        let helper = std::env::current_exe()?
            .parent()
            .unwrap()
            .join("../Helpers/GameNight Link.app");
        if helper.is_dir() {
            std::process::Command::new("open")
                .args(["-gj"])
                .arg(helper)
                .args(["--args", "--register"])
                .status()?;
        }
    }
    Ok(())
}

#[cfg(windows)]
pub fn unregister() -> io::Result<()> {
    use std::os::windows::process::CommandExt;
    let command = format!(
        "\"{}\" --open-url \"%1\"",
        std::env::current_exe()?.display()
    );
    let current = std::process::Command::new("reg.exe")
        .args([
            "query",
            "HKCU\\Software\\Classes\\gamenight\\shell\\open\\command",
            "/ve",
        ])
        .creation_flags(0x08000000)
        .output()?;
    // Removing Preview must not unregister a subsequently installed stable app.
    if String::from_utf8_lossy(&current.stdout).contains(&command) {
        std::process::Command::new("reg.exe")
            .args(["delete", "HKCU\\Software\\Classes\\gamenight", "/f"])
            .creation_flags(0x08000000)
            .stdout(std::process::Stdio::null())
            .status()?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn accepts_only_catalog_game_links() {
        assert_eq!(game("gamenight://play/blast-party"), Some("blast-party"));
        for invalid in [
            "gamenight://play/",
            "gamenight://play/lobby",
            "gamenight://play/demo-game",
            "gamenight://play/../evil",
            "gamenight://play/%62last-party",
            "gamenight://play/game?exec=x",
            "gamenight://play/GAME",
            "https://example.org",
            "gamenight://evil/game",
        ] {
            assert_eq!(game(invalid), None, "{invalid}");
        }
    }
}
