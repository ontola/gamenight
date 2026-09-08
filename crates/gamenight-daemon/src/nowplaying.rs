//! What the host already has playing, and how the party gets at it.
//!
//! Somebody puts music on before the first match — it's the host's laptop,
//! the host's Spotify, and for the rest of the evening it's the host who has
//! to get up when a track lands wrong. This module is what lets the lobby show
//! the room what's on and hand the skip button to whoever's holding a
//! controller.
//!
//! There is no cross-platform "what is playing" API, so this asks the players
//! themselves: AppleScript on macOS, MPRIS (via `playerctl`) on Linux. Both
//! are per-app, which is why [`NowPlaying::source`] carries the app's own name
//! — it isn't decoration, it's the handle [`control`] talks back through.
//!
//! What this deliberately cannot see: audio from a browser tab, a game, or any
//! app that isn't a scriptable music player. Reaching those on macOS needs the
//! private MediaRemote framework, which since macOS 15.4 requires an
//! entitlement Apple doesn't hand out. A YouTube mix stays the host's problem.

use std::time::Duration;

use gamenight_protocol::{MediaAction, NowPlaying};
use tracing::debug;
#[cfg(any(target_os = "macos", target_os = "linux"))]
use tracing::warn;

/// How often the daemon asks the OS what's on.
///
/// Slow enough that it costs nothing (one short-lived process, and only when a
/// player is actually running), fast enough that standing on the skip pad and
/// watching the lobby update feels like cause and effect.
pub const POLL_INTERVAL: Duration = Duration::from_secs(2);

/// Long enough for a busy player to answer, short enough that a wedged one
/// doesn't stall the watcher for the rest of the night.
#[cfg(any(target_os = "macos", target_os = "linux"))]
const QUERY_TIMEOUT: Duration = Duration::from_secs(5);

/// The players we know how to talk to, most likely first.
///
/// On macOS these are both process names (for the "is it even running" check,
/// which costs nothing and asks nobody's permission) and AppleScript
/// application names.
#[cfg(target_os = "macos")]
const PLAYERS: &[&str] = &["Spotify", "Music"];

/// Ask the OS what's playing right now.
///
/// `None` means nothing is: no player running, nothing loaded, or a platform
/// we have no way to ask.
pub async fn poll() -> Option<NowPlaying> {
    platform::poll().await
}

/// Do what a player asked of the host's music.
///
/// `source` is a [`NowPlaying::source`] the poll produced — the app the music
/// is coming from. It is validated against the players we know rather than
/// pasted into a script, because a value that reaches an interpreter should
/// never be one we merely believe we produced.
pub async fn control(source: &str, action: MediaAction) {
    platform::control(source, action).await
}

/// What the party should actually see, given a fresh reading and what they're
/// seeing now.
///
/// The rule is "music the party put on stays on screen; music they never put
/// on never appears". A paused player is only shown once it has been playing —
/// otherwise every host with Spotify open-but-idle gets a lobby card for a
/// track from last Tuesday. Once it *has* been playing, a pause keeps the card
/// up, because the pad that paused it is the pad that resumes it.
fn visible(reading: Option<NowPlaying>, showing: Option<&NowPlaying>) -> Option<NowPlaying> {
    let reading = reading?;
    if reading.playing {
        return Some(reading);
    }
    // Same source we're already showing: this is the party's own pause.
    // Anything else is a player that was idle when we found it.
    showing
        .is_some_and(|shown| shown.source == reading.source)
        .then_some(reading)
}

/// Watch the host's music until the process ends, feeding every change to
/// `on_change`.
///
/// Only changes are reported: the poll runs on a timer and the answer is the
/// same one nearly every time, while each change costs a full party snapshot
/// broadcast to every screen in the house.
pub async fn watch<F>(mut on_change: F)
where
    F: FnMut(Option<NowPlaying>),
{
    let mut showing: Option<NowPlaying> = None;
    loop {
        tokio::time::sleep(POLL_INTERVAL).await;
        let next = visible(poll().await, showing.as_ref());
        if next == showing {
            continue;
        }
        match &next {
            Some(t) => {
                debug!(title = %t.title, playing = t.playing, source = %t.source, "host music changed")
            }
            None => debug!("host music stopped"),
        }
        showing = next.clone();
        on_change(next);
    }
}

/// Run a command, giving up rather than waiting on a wedged player. `None`
/// covers every kind of "no answer": the binary isn't there, the app said no,
/// it took too long.
#[cfg(any(target_os = "macos", target_os = "linux"))]
async fn output(program: &str, args: &[&str]) -> Option<String> {
    let child = tokio::process::Command::new(program)
        .args(args)
        .kill_on_drop(true)
        .output();
    match tokio::time::timeout(QUERY_TIMEOUT, child).await {
        Ok(Ok(out)) if out.status.success() => Some(String::from_utf8_lossy(&out.stdout).into()),
        // A player that isn't playing answers with an error as often as not
        // ("no current track"), so this is the normal quiet case, not a fault.
        Ok(Ok(_)) => None,
        Ok(Err(e)) => {
            debug!(program, error = %e, "could not ask about the host's music");
            None
        }
        Err(_) => {
            warn!(program, "gave up waiting for the host's music player");
            None
        }
    }
}

#[cfg(target_os = "macos")]
mod platform {
    use super::*;

    /// Ask each player we know about, preferring one that's actually playing
    /// over one that's merely open — with both Spotify and Music running, the
    /// party means the one making noise.
    pub(super) async fn poll() -> Option<NowPlaying> {
        let mut paused = None;
        for app in PLAYERS {
            if !is_running(app).await {
                continue;
            }
            match query(app).await {
                Some(track) if track.playing => return Some(track),
                Some(track) => paused = paused.or(Some(track)),
                None => {}
            }
        }
        paused
    }

    pub(super) async fn control(source: &str, action: MediaAction) {
        let Some(app) = PLAYERS.iter().find(|p| **p == source) else {
            warn!(source, "asked to control a music player we don't know");
            return;
        };
        let verb = match action {
            MediaAction::PlayPause => "playpause",
            MediaAction::NextTrack => "next track",
            MediaAction::PreviousTrack => "previous track",
        };
        debug!(app, verb, "controlling the host's music");
        output(
            "osascript",
            &["-e", &format!("tell application \"{app}\" to {verb}")],
        )
        .await;
    }

    /// Whether the app is up, asked of the process table rather than of the
    /// app.
    ///
    /// Two reasons it has to be this way round. AppleScript's own `tell` will
    /// happily *launch* a player that wasn't running to answer the question,
    /// which is a rude thing to do to somebody's machine every two seconds.
    /// And talking to another app at all is what triggers the OS automation
    /// prompt — a host who never opens Spotify should never be asked to
    /// approve GameNight talking to it.
    async fn is_running(app: &str) -> bool {
        output("pgrep", &["-x", app]).await.is_some()
    }

    /// One AppleScript round trip: state, title, artist, tab-separated.
    ///
    /// `player state` is checked before `current track` because asking a
    /// stopped player what's loaded is an error, not an empty answer.
    async fn query(app: &str) -> Option<NowPlaying> {
        let script = format!(
            r#"tell application "{app}"
                if player state is stopped then return ""
                set t to current track
                return (player state as text) & tab & (name of t) & tab & (artist of t)
            end tell"#
        );
        parse(&output("osascript", &["-e", &script]).await?, app)
    }

    /// `playing<tab>title<tab>artist` into a [`NowPlaying`].
    ///
    /// A track with no title is treated as nothing playing: "" on the lobby's
    /// music card is worse than no card.
    fn parse(raw: &str, app: &str) -> Option<NowPlaying> {
        let mut fields = raw.trim_end_matches('\n').split('\t');
        let state = fields.next()?.trim();
        let title = fields.next().unwrap_or_default().trim();
        let artist = fields.next().unwrap_or_default().trim();
        if title.is_empty() {
            return None;
        }
        Some(NowPlaying {
            title: title.to_string(),
            artist: artist.to_string(),
            // Music's fast-forward and rewind are still the track running.
            playing: matches!(state, "playing" | "fast forwarding" | "rewinding"),
            source: app.to_string(),
        })
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn reads_what_spotify_says() {
            let track = parse("playing\tIn Paradisum\tGabriel Fauré\n", "Spotify").unwrap();
            assert_eq!(track.title, "In Paradisum");
            assert_eq!(track.artist, "Gabriel Fauré");
            assert_eq!(track.source, "Spotify");
            assert!(track.playing);

            assert!(
                !parse("paused\tIn Paradisum\tGabriel Fauré", "Spotify")
                    .unwrap()
                    .playing
            );
            // Music, scrubbing: still the track, still playing.
            assert!(
                parse("fast forwarding\tIn Paradisum\t", "Music")
                    .unwrap()
                    .playing
            );
            // A local file with no tags still has a name worth showing.
            assert_eq!(
                parse("playing\ttrack01\t", "Music").unwrap().artist,
                "",
                "a missing artist should read as none, not as a phantom field"
            );
            // Stopped: the script's own "nothing here" answer.
            assert!(parse("", "Spotify").is_none());
            assert!(parse("playing\t\t", "Spotify").is_none());
        }
    }
}

/// MPRIS, through `playerctl` — the same bargain as the macOS side: we talk to
/// whatever the desktop's players already publish, and if `playerctl` isn't
/// installed the lobby simply never shows a music card.
#[cfg(target_os = "linux")]
mod platform {
    use super::*;

    const FORMAT: &str = "{{status}}\t{{title}}\t{{artist}}\t{{playerName}}";

    pub(super) async fn poll() -> Option<NowPlaying> {
        parse(&output("playerctl", &["metadata", "--format", FORMAT]).await?)
    }

    pub(super) async fn control(source: &str, action: MediaAction) {
        // `source` is a player name we produced, and it becomes an argument to
        // another program — check it looks like one rather than trusting where
        // it came from.
        if source.is_empty()
            || !source
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
        {
            warn!(source, "asked to control a music player we don't know");
            return;
        }
        let verb = match action {
            MediaAction::PlayPause => "play-pause",
            MediaAction::NextTrack => "next",
            MediaAction::PreviousTrack => "previous",
        };
        debug!(source, verb, "controlling the host's music");
        output("playerctl", &["-p", source, verb]).await;
    }

    fn parse(raw: &str) -> Option<NowPlaying> {
        let mut fields = raw.trim_end_matches('\n').split('\t');
        let status = fields.next()?.trim();
        let title = fields.next().unwrap_or_default().trim();
        let artist = fields.next().unwrap_or_default().trim();
        let player = fields.next().unwrap_or_default().trim();
        if title.is_empty() {
            return None;
        }
        Some(NowPlaying {
            title: title.to_string(),
            artist: artist.to_string(),
            playing: status.eq_ignore_ascii_case("playing"),
            source: player.to_string(),
        })
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn reads_what_playerctl_says() {
            let track = parse("Playing\tIn Paradisum\tGabriel Fauré\tspotify\n").unwrap();
            assert_eq!(track.title, "In Paradisum");
            assert_eq!(track.source, "spotify");
            assert!(track.playing);
            assert!(
                !parse("Paused\tIn Paradisum\tGabriel Fauré\tvlc")
                    .unwrap()
                    .playing
            );
            assert!(parse("Stopped\t\t\tvlc").is_none());
        }
    }
}

/// Everywhere else: no music card, and nothing pretending there could be one.
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
mod platform {
    use super::*;

    pub(super) async fn poll() -> Option<NowPlaying> {
        None
    }

    pub(super) async fn control(_source: &str, _action: MediaAction) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    fn track(source: &str, playing: bool) -> NowPlaying {
        NowPlaying {
            title: "In Paradisum".into(),
            artist: "Gabriel Fauré".into(),
            playing,
            source: source.into(),
        }
    }

    /// A player that was already sitting paused when the daemon started is not
    /// the party's music, and putting it on the lobby wall claims otherwise.
    #[test]
    fn an_idle_player_never_reaches_the_lobby() {
        assert_eq!(visible(Some(track("Spotify", false)), None), None);
        assert_eq!(visible(None, None), None);
    }

    /// Once it's the party's music, pausing keeps the card — that card is the
    /// only way anybody gets it started again.
    #[test]
    fn pausing_keeps_the_card_up() {
        let playing = track("Spotify", true);
        assert_eq!(visible(Some(playing.clone()), None), Some(playing.clone()));

        let paused = track("Spotify", false);
        assert_eq!(
            visible(Some(paused.clone()), Some(&playing)),
            Some(paused.clone())
        );
        // And it stays up while it stays paused.
        assert_eq!(visible(Some(paused.clone()), Some(&paused)), Some(paused));
    }

    /// Switching apps mid-evening doesn't inherit the last one's welcome: a
    /// second player found paused is still a player nobody asked for.
    #[test]
    fn a_different_player_starts_from_nothing() {
        let spotify = track("Spotify", true);
        assert_eq!(visible(Some(track("Music", false)), Some(&spotify)), None);
        assert_eq!(
            visible(Some(track("Music", true)), Some(&spotify)),
            Some(track("Music", true))
        );
    }

    /// The music being switched off is a change like any other — the card goes.
    #[test]
    fn stopping_takes_the_card_away() {
        assert_eq!(visible(None, Some(&track("Spotify", true))), None);
    }

    /// Ask this actual machine what it's playing. Ignored by default: it
    /// depends on what the person running it happens to have open, and on
    /// macOS the first run may raise the automation prompt.
    ///
    /// `cargo test -p gamenight-daemon -- --ignored --nocapture what_is_playing`
    #[tokio::test]
    #[ignore = "asks the real machine, and the answer depends on the machine"]
    async fn what_is_playing() {
        println!("{:?}", poll().await);
    }
}
