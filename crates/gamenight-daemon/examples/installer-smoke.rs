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
    let content = data::seed_content(root, &data, "pinpals", "fixture-1")?;
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
