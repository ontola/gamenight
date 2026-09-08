//! The background install path, end to end over a real socket.
//!
//! Worth an integration test rather than unit coverage: until the catalogue
//! carries a real `downloads` block this whole path is unreachable in
//! production, so nothing else exercises "HTTP response in, verified file and
//! a progress stream out". The lobby's download bar is only as honest as this.

use std::fmt::Write as _;
use std::net::SocketAddr;

use gamenight_catalog::CatalogEntry;
use gamenight_protocol::InstallState;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

/// Serve `body` once, with a Content-Length, then hang up. Chunked in several
/// writes so the installer's progress loop sees more than a single chunk —
/// a one-shot body would report 100% and prove nothing about the arithmetic.
async fn serve_once(body: Vec<u8>) -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        // Drain the request line/headers so the client isn't writing into a
        // socket nobody reads.
        let mut buf = [0u8; 1024];
        let _ = stream.read(&mut buf).await;

        let header = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        );
        stream.write_all(header.as_bytes()).await.unwrap();
        for chunk in body.chunks(body.len() / 8 + 1) {
            stream.write_all(chunk).await.unwrap();
            stream.flush().await.unwrap();
        }
        let _ = stream.shutdown().await;
    });
    addr
}

fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    h.update(bytes);
    h.finalize().iter().fold(String::new(), |mut s, b| {
        let _ = write!(s, "{b:02x}");
        s
    })
}

fn entry(id: &str, url: &str, sha256: &str) -> CatalogEntry {
    let mut downloads = serde_json::Map::new();
    downloads.insert(
        gamenight_catalog::current_platform().to_string(),
        serde_json::json!({ "url": url, "sha256": sha256 }),
    );
    serde_json::from_value(serde_json::json!({
        "id": id,
        "title": "Growing Guns",
        "players": { "min": 2, "max": 4, "best": 2 },
        "price": "free",
        "integration": { "level": "certified" },
        "downloads": downloads,
    }))
    .unwrap()
}

fn tmp_root(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("gamenight-install-test-{name}"));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

#[tokio::test]
async fn a_download_reports_its_way_to_installed() {
    // Big enough that eight chunks straddle several whole percents.
    let body: Vec<u8> = (0..64_000u32).map(|i| (i % 251) as u8).collect();
    let sha = sha256_hex(&body);
    let addr = serve_once(body.clone()).await;
    let root = tmp_root("progress");

    let entry = entry("growing-guns", &format!("http://{addr}/game-bin"), &sha);
    let (tx, mut rx) = gamenight_installer::progress_channel();
    let installed = gamenight_installer::ensure_installed_reporting(&entry, &root, Some(&tx))
        .await
        .expect("the download should verify and extract");
    drop(tx);

    // The file really is on disk, byte-identical, and where the launch spec
    // says it is — a progress bar over a corrupt install is worse than none.
    assert_eq!(
        std::fs::read(&installed.executable).unwrap(),
        body,
        "the extracted binary should match what was served"
    );
    assert_eq!(
        installed.launch_spec().command,
        installed.executable.display().to_string()
    );

    let mut reports = Vec::new();
    while let Ok(status) = rx.try_recv() {
        reports.push(status);
    }

    assert!(
        reports.iter().all(|r| r.title == "Growing Guns"),
        "every report should name the game, so a screen can label it before \
         any shelf entry for it exists"
    );

    let states: Vec<_> = reports.iter().map(|r| r.state).collect();
    assert!(states.contains(&InstallState::Downloading));
    assert!(states.contains(&InstallState::Verifying));
    assert_eq!(
        states.last(),
        Some(&InstallState::Installed),
        "the last thing the party hears should be that it's playable"
    );

    // Percentages only ever move forward, and only while downloading.
    let percents: Vec<u8> = reports
        .iter()
        .filter(|r| r.state == InstallState::Downloading)
        .filter_map(|r| r.percent)
        .collect();
    assert!(
        percents.len() > 2,
        "a multi-chunk download should report more than a couple of steps, got {percents:?}"
    );
    assert!(
        percents.windows(2).all(|w| w[0] < w[1]),
        "progress must be strictly increasing, got {percents:?}"
    );
    assert_eq!(percents.last(), Some(&100));

    let _ = std::fs::remove_dir_all(&root);
}

/// A tampered or truncated download must not become a shelf entry, and the
/// party must be told why rather than watching a bar sit still forever.
#[tokio::test]
async fn a_hash_mismatch_fails_loudly_and_installs_nothing() {
    let body: Vec<u8> = b"not the game you were promised".to_vec();
    let addr = serve_once(body).await;
    let root = tmp_root("mismatch");

    let entry = entry(
        "growing-guns",
        &format!("http://{addr}/game-bin"),
        &"a".repeat(64),
    );
    let (tx, mut rx) = gamenight_installer::progress_channel();
    let result = gamenight_installer::ensure_installed_reporting(&entry, &root, Some(&tx)).await;
    drop(tx);

    assert!(result.is_err(), "a bad hash must not install");
    assert!(
        !root.join("growing-guns").join("game-bin").exists(),
        "nothing from a failed verify should be left runnable"
    );

    let mut reports = Vec::new();
    while let Ok(status) = rx.try_recv() {
        reports.push(status);
    }
    let last = reports.last().expect("failure should still be reported");
    assert_eq!(last.state, InstallState::Failed);
    assert!(
        last.label.as_deref().is_some_and(|l| l.contains("sha256")),
        "the reason should travel with the failure, got {:?}",
        last.label
    );

    let _ = std::fs::remove_dir_all(&root);
}
