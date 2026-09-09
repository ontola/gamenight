//! Portable Windows preview entry point. No shell scripts or installation needed.
use std::{fs, io, net::TcpListener, process::Command};

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
    let local = root.join(".local");
    fs::create_dir_all(&local)?;
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
    println!("GameNight is running. Press Enter here to close GameNight and its games.");
    let input = io::stdin().read_line(&mut String::new());
    // Scope cleanup to this launch's process tree, including hidden warm games.
    stop_tree(&mut child)?;
    input?;
    Ok(())
}

fn stop_tree(child: &mut std::process::Child) -> io::Result<()> {
    if child.try_wait()?.is_none() {
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            let status = Command::new("taskkill")
                .args(["/PID", &child.id().to_string(), "/T", "/F"])
                .creation_flags(0x08000000)
                .output()?
                .status;
            if !status.success() && child.try_wait()?.is_none() {
                return Err(io::Error::other("Could not close GameNight's process tree"));
            }
        }
        #[cfg(not(windows))]
        child.kill()?;
        child.wait()?;
    }
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("GameNight could not start or close: {error}\nPress Enter to close.");
        let _ = io::stdin().read_line(&mut String::new());
        std::process::exit(1);
    }
}
