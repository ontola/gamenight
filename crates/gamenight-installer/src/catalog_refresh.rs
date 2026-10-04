//! Refresh only from the launcher's trusted HTTPS publishing origin.
//! The whole snapshot is validated before atomic replacement; offline play uses the last copy.
use futures_util::StreamExt;
use gamenight_catalog::PublishedCatalog;
use std::path::Path;

pub async fn refresh(url: &str, destination: &Path) -> Result<bool, String> {
    let parsed = reqwest::Url::parse(url).map_err(|_| "Invalid catalog URL")?;
    if parsed.scheme() != "https"
        || parsed.host_str().is_none()
        || !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.fragment().is_some()
    {
        return Err("Catalog feeds require HTTPS without credentials".into());
    }
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(std::time::Duration::from_secs(15))
        .build()
        .map_err(|e| e.to_string())?;
    let response = client
        .get(parsed)
        .send()
        .await
        .map_err(|e| e.to_string())?
        .error_for_status()
        .map_err(|e| e.to_string())?;
    let mut stream = response.bytes_stream();
    let mut bytes = Vec::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| e.to_string())?;
        if bytes.len() + chunk.len() > 16 * 1024 * 1024 {
            return Err("Catalog exceeds 16 MiB".into());
        }
        bytes.extend_from_slice(&chunk);
    }
    let feed: PublishedCatalog = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
    validate(&feed)?;
    if tokio::fs::read(destination).await.ok().as_deref() == Some(bytes.as_slice()) {
        return Ok(false);
    }
    let parent = destination.parent().ok_or("Missing catalog parent")?;
    tokio::fs::create_dir_all(parent)
        .await
        .map_err(|e| e.to_string())?;
    let stage = parent.join(format!(".catalog-{}", uuid::Uuid::new_v4()));
    let result = async {
        use tokio::io::AsyncWriteExt;
        let mut file = tokio::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&stage)
            .await
            .map_err(|e| e.to_string())?;
        file.write_all(&bytes).await.map_err(|e| e.to_string())?;
        file.sync_all().await.map_err(|e| e.to_string())?;
        drop(file);
        tokio::fs::rename(&stage, destination)
            .await
            .map_err(|e| e.to_string())?;
        Ok(true)
    }
    .await;
    let _ = tokio::fs::remove_file(stage).await;
    result
}

fn validate(feed: &PublishedCatalog) -> Result<(), String> {
    if feed.schema != 1 {
        return Err("Unsupported catalog schema".into());
    }
    gamenight_catalog::validate_published(&feed.games).map_err(|errors| errors.join("; "))?;
    let encoded = serde_json::to_vec(&feed.games).map_err(|e| e.to_string())?;
    // Revision is an opaque server identity; its hash uses the server's JSON encoding.
    if feed.revision.len() != 64
        || !feed.revision.bytes().all(|b| b.is_ascii_hexdigit())
        || encoded.len() > 16 * 1024 * 1024
    {
        return Err("Invalid catalog revision".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn protects_host_and_rejects_invalid_or_insecure_downloads() {
        let mut game: gamenight_catalog::CatalogEntry =
            serde_json::from_str(include_str!("../../../catalog/games/frog-fighter.json")).unwrap();
        let mut feed = PublishedCatalog {
            schema: 1,
            revision: "a".repeat(64),
            games: vec![game.clone()],
        };
        assert!(validate(&feed).is_ok());
        game.id = "lobby".into();
        feed.games = vec![game.clone()];
        assert!(validate(&feed).is_err());
        game.id = "frog-fighter".into();
        game.downloads.get_mut("windows").unwrap().url = "http://example.com/game.zip".into();
        feed.games = vec![game];
        assert!(validate(&feed).is_err());
        feed.games.clear();
        feed.schema = 2;
        assert!(validate(&feed).is_err());
    }
}
