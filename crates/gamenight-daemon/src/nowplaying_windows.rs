use super::*;
use windows::Media::Control::{
    GlobalSystemMediaTransportControlsSession as Session,
    GlobalSystemMediaTransportControlsSessionManager as Manager,
    GlobalSystemMediaTransportControlsSessionPlaybackStatus as Status,
};
use windows::Win32::System::WinRT::{RoInitialize, RoUninitialize, RO_INIT_MULTITHREADED};
struct Apartment;
impl Apartment {
    fn new() -> windows::core::Result<Self> {
        unsafe {
            RoInitialize(RO_INIT_MULTITHREADED)?;
        }
        Ok(Self)
    }
}
impl Drop for Apartment {
    fn drop(&mut self) {
        unsafe {
            RoUninitialize();
        }
    }
}
fn reading(session: &Session) -> windows::core::Result<Option<NowPlaying>> {
    let properties = session.TryGetMediaPropertiesAsync()?.get()?;
    let title = properties.Title()?.to_string();
    if title.trim().is_empty() {
        return Ok(None);
    }
    Ok(Some(NowPlaying {
        title,
        artist: properties.Artist()?.to_string(),
        source: session.SourceAppUserModelId()?.to_string(),
        playing: session.GetPlaybackInfo()?.PlaybackStatus()? == Status::Playing,
    }))
}
fn poll_sync() -> windows::core::Result<Option<NowPlaying>> {
    let _apartment = Apartment::new()?;
    let manager = Manager::RequestAsync()?.get()?;
    let current = manager
        .GetCurrentSession()
        .ok()
        .and_then(|s| reading(&s).ok().flatten());
    if current.as_ref().is_some_and(|t| t.playing) {
        return Ok(current);
    }
    for session in manager.GetSessions()? {
        if let Ok(Some(track)) = reading(&session) {
            if track.playing {
                return Ok(Some(track));
            }
        }
    }
    Ok(current)
}
pub(super) async fn poll() -> Option<NowPlaying> {
    match tokio::task::spawn_blocking(poll_sync).await {
        Ok(Ok(track)) => track,
        result => {
            debug!(?result, "Windows media session query failed");
            None
        }
    }
}
pub(super) async fn control(source: &str, action: MediaAction) {
    let source = source.to_owned();
    let result = tokio::task::spawn_blocking(move || -> windows::core::Result<()> {
        let _apartment = Apartment::new()?;
        let manager = Manager::RequestAsync()?.get()?;
        for session in manager.GetSessions()? {
            if session.SourceAppUserModelId()?.to_string() != source {
                continue;
            }
            let accepted = match action {
                MediaAction::PlayPause => session.TryTogglePlayPauseAsync()?.get()?,
                MediaAction::NextTrack => session.TrySkipNextAsync()?.get()?,
                MediaAction::PreviousTrack => session.TrySkipPreviousAsync()?.get()?,
            };
            debug!(accepted, "Windows media command completed");
            break;
        }
        Ok(())
    })
    .await;
    if !matches!(result, Ok(Ok(()))) {
        debug!(?result, "Windows media command failed");
    }
}
