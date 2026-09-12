//! Opt-in development assets. Installed builds keep using embedded files.
use axum::{
    extract::Request,
    http::StatusCode,
    middleware::Next,
    response::{IntoResponse, Response},
};
use std::path::{Path, PathBuf};

fn asset(path: &str) -> Option<(&str, &'static str)> {
    let name = path
        .strip_prefix("/web/")
        .or_else(|| path.strip_prefix("/assets/"))
        .unwrap_or_else(|| path.trim_start_matches('/'));
    let mime = match name {
        "studio.js" | "storage.js" | "account.js" | "shell.js" | "qr-scanner.js" | "jsQR.js" => {
            "text/javascript"
        }
        "studio.css" | "site.css" | "account.css" => "text/css",
        "icon.svg" => "image/svg+xml",
        "favicon.ico" => "image/x-icon",
        "apple-touch-icon.png" => "image/png",
        _ => return None,
    };
    Some((name, mime))
}

async fn file(root: &Path, name: &str, mime: &'static str) -> Response {
    match tokio::fs::read(root.join(name)).await {
        Ok(bytes) => (
            [("content-type", mime), ("cache-control", "no-store")],
            bytes,
        )
            .into_response(),
        Err(error) => {
            tracing::warn!(%error, name, "Development web file unavailable");
            (StatusCode::NOT_FOUND, "Development web file unavailable").into_response()
        }
    }
}

pub async fn assets(request: Request, next: Next) -> Response {
    if let Some(root) = std::env::var_os("GAMENIGHT_DEV_WEB_DIR") {
        if let Some((name, mime)) = asset(request.uri().path()) {
            return file(&PathBuf::from(root), name, mime).await;
        }
    }
    next.run(request).await
}

pub async fn studio() -> Option<Response> {
    let root = PathBuf::from(std::env::var_os("GAMENIGHT_DEV_WEB_DIR")?);
    Some(file(&root, "studio.html", "text/html; charset=utf-8").await)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_public_assets_are_allowed() {
        assert!(asset("/web/studio.css").is_some());
        for path in [
            "/web/../Cargo.toml",
            "/web/%2e%2e/secret",
            "/api/profiles",
            "/studio",
            "/assets/secret.json",
        ] {
            assert!(asset(path).is_none());
        }
    }
    #[tokio::test]
    async fn edits_are_visible_without_restart() {
        let root = std::env::temp_dir().join(format!("gamenight-web-{}", uuid::Uuid::new_v4()));
        tokio::fs::create_dir(&root).await.unwrap();
        for text in ["first", "edited"] {
            tokio::fs::write(root.join("studio.css"), text)
                .await
                .unwrap();
            let response = file(&root, "studio.css", "text/css").await;
            assert_eq!(response.headers()["cache-control"], "no-store");
            assert_eq!(
                axum::body::to_bytes(response.into_body(), 100)
                    .await
                    .unwrap(),
                text
            );
        }
        tokio::fs::remove_dir_all(root).await.unwrap();
    }
}
