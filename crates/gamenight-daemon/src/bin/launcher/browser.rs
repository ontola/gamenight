//! Open the first-run browser outside the daemon's kill-on-close process tree.
use std::{
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    thread,
    time::Duration,
};

pub struct Worker {
    stop: Arc<AtomicBool>,
    thread: Option<thread::JoinHandle<()>>,
}
impl Worker {
    pub fn start(path: PathBuf) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let cancel = stop.clone();
        let thread = thread::spawn(move || {
            while !cancel.load(Ordering::Relaxed) {
                if let Ok(url) = std::fs::read_to_string(&path) {
                    // A partial write is retried; only a complete capability URL
                    // is opened. Never dispatch arbitrary file/command schemes.
                    if valid_url(&url) {
                        let _ = std::fs::remove_file(&path);
                        let _ = open(&url);
                        continue;
                    }
                }
                thread::sleep(Duration::from_millis(250));
            }
        });
        Self {
            stop,
            thread: Some(thread),
        }
    }
}
impl Drop for Worker {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}
pub fn open_lobby_settings() -> std::io::Result<()> {
    open(&format!(
        "http://127.0.0.1:{}/host/lobby",
        gamenight_protocol::DEFAULT_WEB_PORT
    ))
}
fn valid_url(url: &str) -> bool {
    if url
        == format!(
            "http://127.0.0.1:{}/host/lobby?recovery=1",
            gamenight_protocol::DEFAULT_WEB_PORT
        )
    {
        return true;
    }

    let Some(args) = url.strip_prefix("https://gamenight.ontola.io/play#desktop=") else {
        return false;
    };
    let Some((ticket, rest)) = args.split_once("&port=") else {
        return false;
    };
    let Some((port, platform)) = rest.split_once("&platform=") else {
        return false;
    };
    ticket.len() == 32
        && ticket.bytes().all(|b| b.is_ascii_hexdigit())
        && port.parse::<u16>().is_ok_and(|port| port >= 1024)
        && ["windows", "mac", "linux"].contains(&platform)
}
fn open(url: &str) -> std::io::Result<()> {
    #[cfg(windows)]
    let mut command = {
        use std::os::windows::process::CommandExt;
        let mut cmd = std::process::Command::new("rundll32.exe");
        cmd.args(["url.dll,FileProtocolHandler", url])
            .creation_flags(0x08000000);
        cmd
    };
    #[cfg(target_os = "macos")]
    let mut command = {
        let mut cmd = std::process::Command::new("open");
        cmd.arg(url);
        cmd
    };
    #[cfg(not(any(windows, target_os = "macos")))]
    let mut command = {
        let mut cmd = std::process::Command::new("xdg-open");
        cmd.arg(url);
        cmd
    };
    // Reap the helper separately; the browser itself is never waited on or killed.
    let mut child = command.spawn()?;
    thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn browser_request_cannot_open_arbitrary_urls_or_partial_writes() {
        let good="https://gamenight.ontola.io/play#desktop=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&port=7913&platform=windows";
        assert!(valid_url(good));
        assert!(valid_url("http://127.0.0.1:7913/host/lobby?recovery=1"));
        assert!(!valid_url("http://192.0.2.1:7913/host/lobby?recovery=1"));
        assert!(!valid_url(
            "http://127.0.0.1:7913/host/lobby?recovery=1&url=evil"
        ));
        for bad in [
            "file:///tmp/anything",
            "https://evil.test/play",
            &good[..good.len() - 1],
            &good.replace("port=7913", "port=0"),
            &format!("{good}&url=file:///anything"),
        ] {
            assert!(!valid_url(bad));
        }
    }
}
