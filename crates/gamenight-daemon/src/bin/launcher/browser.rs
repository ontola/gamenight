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
fn valid_url(url: &str) -> bool {
    ["windows", "mac", "linux"].iter().any(|platform| url == format!("{}/play#setup={platform}", gamenight_protocol::web_base_url().trim_end_matches('/')))
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
    fn only_hosted_setup_can_be_opened() {
        assert!(valid_url("https://gamenight.ontola.io/play#setup=windows"));
        for url in ["http://127.0.0.1:7913/host/lobby", "file:///tmp/code", "https://evil.test/play#setup=windows", "https://gamenight.ontola.io/play#setup=windows&url=evil"] { assert!(!valid_url(url)); }
    }
}
