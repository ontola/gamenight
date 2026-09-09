//! Windows desktop entry point, shared by the installer and portable preview.
#![cfg_attr(windows, windows_subsystem = "windows")]
#[path = "launcher/data.rs"]
mod data;
#[cfg(windows)]
#[path = "launcher/windows.rs"]
mod windows;
#[cfg(windows)]
use std::io;
use std::{
    fs,
    io::Write,
    net::TcpListener,
    process::{Command, Stdio},
};

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let executable = std::env::current_exe()?;
    let root = executable.parent().ok_or("No package directory")?;
    let port: u16 = std::env::args()
        .nth(1)
        .map(|v| v.parse())
        .transpose()?
        .unwrap_or(7912);
    if port == 0 {
        return Err("Port must not be zero".into());
    }
    // Fail before launching anything if another GameNight owns the port.
    drop(TcpListener::bind(("127.0.0.1", port))?);
    let daemon = root.join("bin/gamenight-daemon.exe");
    let lobby = root.join("bin/lobby.exe");
    let love = root.join("love/love.exe");
    let game_dir = root.join("pinpals");
    let lobby_dir = root.join("lobby");
    for path in [&daemon, &lobby, &love, &game_dir.join("main.lua")] {
        if !path.is_file() {
            return Err(format!("Missing package file: {}", path.display()).into());
        }
    }
    let local = data::user_dir()?;
    fs::create_dir_all(&local)?;
    let lock = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(local.join("launcher.lock"))?;
    lock.try_lock()
        .map_err(|_| "GameNight is already running")?;
    // Versioned content stays outside Velopack's replaceable application folder.
    let love_dir = data::seed_content(root, &local, "love", "11.5")?;
    let game_dir = data::seed_content(
        root,
        &local,
        "pinpals",
        "95ea42fe544cf3906c90aeb556359180964c1e88",
    )?;
    let love = love_dir.join("love.exe");
    #[cfg(windows)]
    let updates = windows::Updates::start(&local);
    let shelf = serde_json::json!([
        {"id":"pinpals", "title":"Pinpals", "players":"2", "min_players":2, "max_players":2,
         "emoji":"", "color":"#f5a742", "launch":{"command":love, "args":[game_dir], "cwd":game_dir}},
        {"id":"lobby", "title":"GameNight", "players":"1-4", "min_players":1, "max_players":4,
         "emoji":"", "color":"#7c5cff", "launch":{"command":lobby, "cwd":lobby_dir,
         "env":{"BEVY_ASSET_ROOT":lobby_dir}}}
    ]);
    let shelf_path = local.join("shelf.json");
    fs::write(&shelf_path, serde_json::to_vec_pretty(&shelf)?)?;
    let mut command = Command::new(daemon);
    command
        .current_dir(root)
        .env("GAMENIGHT_ADDR", format!("127.0.0.1:{port}"))
        .env("GAMENIGHT_LIBRARY", shelf_path)
        .env("GAMENIGHT_NO_PREWARM", "1")
        .env("GAMENIGHT_EXIT_WITH_LOBBY", "1")
        .env("GAMENIGHT_STARTUP_GATE", "1")
        .stdin(Stdio::piped())
        .env("RUST_LOG", "info")
        .stdout(fs::File::create(local.join("daemon.log"))?)
        .stderr(fs::File::create(local.join("daemon-errors.log"))?);
    for key in [
        "GAMENIGHT",
        "GAMENIGHT_GAME_ID",
        "GAMENIGHT_TOKEN",
        "GAMENIGHT_NO_LOBBY_WATCH",
        "GAMENIGHT_WEB",
    ] {
        command.env_remove(key);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000); // CREATE_NO_WINDOW
    }
    let mut child = command.spawn()?;
    #[cfg(windows)]
    let job = match windows::ProcessTree::attach(&child) {
        Ok(job) => job,
        Err(error) => {
            stop_tree(&mut child)?;
            return Err(error.into());
        }
    };
    child
        .stdin
        .take()
        .ok_or("Missing startup pipe")?
        .write_all(&[1])?;
    let status = child.wait();
    #[cfg(windows)]
    job.close()?; // No hidden game or descendant may survive into an update.
    if !status?.success() {
        return Err(format!(
            "The GameNight host stopped unexpectedly. See {}",
            local.join("daemon-errors.log").display()
        )
        .into());
    }
    #[cfg(windows)]
    updates.apply_on_exit();
    Ok(())
}

#[cfg(windows)]
fn stop_tree(child: &mut std::process::Child) -> io::Result<()> {
    // Before the startup pipe is released, this child cannot have descendants.
    if child.try_wait()?.is_none() {
        child.kill()?;
        child.wait()?;
    }
    Ok(())
}

fn main() {
    #[cfg(windows)]
    velopack::VelopackApp::build()
        .set_auto_apply_on_startup(false)
        .run();
    if let Err(error) = run() {
        #[cfg(windows)]
        windows::show_error(&error.to_string());
        #[cfg(not(windows))]
        eprintln!("GameNight could not start or close: {error}");
        std::process::exit(1);
    }
}
