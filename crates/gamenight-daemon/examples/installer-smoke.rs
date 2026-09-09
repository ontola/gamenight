//! Isolated installer/update integration fixture. Never included in release packages.
#[cfg(windows)]
#[allow(dead_code)]
#[path = "../src/bin/launcher/data.rs"]
mod data;
#[cfg(windows)]
#[allow(dead_code)]
#[path = "../src/bin/launcher/windows.rs"]
mod windows;

#[cfg(windows)]
fn main() -> Result<(), Box<dyn std::error::Error>> {
    velopack::VelopackApp::build()
        .set_auto_apply_on_startup(false)
        .run();
    if std::env::args().any(|arg| arg == "--child") {
        std::thread::sleep(std::time::Duration::from_secs(120));
        return Ok(());
    }
    let Some(feed) = std::env::var_os("GAMENIGHT_SMOKE_FEED") else {
        return Ok(());
    };
    let data = data::user_dir()?;
    std::fs::create_dir_all(&data)?;
    let exe = std::env::current_exe()?;
    let root = exe.parent().unwrap();
    let source = velopack::sources::FileSource::new(feed);
    let manager = velopack::UpdateManager::new(source.clone(), None, None)?;
    let content = seed_content(root, &data, "pinpals", "fixture-1")?;
    let updates = windows::Updates::with_source(&data, source);
    use std::os::windows::process::CommandExt;
    let child = std::process::Command::new(&exe)
        .arg("--child")
        .creation_flags(0x08000000)
        .spawn()?;
    let job = windows::ProcessTree::attach(&child)?;
    std::fs::write(
        data.join("running.tmp"),
        serde_json::to_vec(&serde_json::json!({
            "version": manager.get_current_version_as_string(), "pid": std::process::id(),
            "child":child.id(), "content":content
        }))?,
    )?;
    std::fs::rename(data.join("running.tmp"), data.join("running.json"))?;
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(90);
    while !data.join("exit").exists() {
        if std::time::Instant::now() > deadline {
            return Err("smoke fixture timed out".into());
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    job.close()?;
    std::fs::write(data.join("children-closed"), "yes")?;
    updates.apply_on_exit();
    Ok(())
}
#[cfg(not(windows))]
fn main() {}

#[cfg(any(windows, test))]
use std::{fs, io, path::PathBuf};

/// Seed immutable content once. A partial copy is never considered installed.
/// Shipping the seed also lets a fresh install start without a network connection.
#[cfg(any(windows, test))]
fn seed_content(
    package: &std::path::Path,
    data: &std::path::Path,
    name: &str,
    version: &str,
) -> io::Result<PathBuf> {
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

#[cfg(any(windows, test))]
fn copy_tree(source: &std::path::Path, destination: &std::path::Path) -> io::Result<()> {
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
