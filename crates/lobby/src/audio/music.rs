use bones_framework::prelude::kira::{
    sound::{static_sound::StaticSoundSettings, PlaybackState},
    tween::Tween,
};

use crate::prelude::*;

/// The music playback state.
#[derive(HasSchema, Default, PartialEq, Eq)]
#[schema(no_clone)]
pub enum MusicState {
    /// Music is not playing.
    #[default]
    None,
    /// Playing the fight music.
    Fight {
        /// The index of the song in the shuffled playlist.
        idx: usize,
    },
}

/// Bevy resource containing the in-game music playlist shuffled.
#[derive(HasSchema, Deref, DerefMut, Clone, Default)]
#[repr(C)]
pub struct ShuffledPlaylist(pub SVec<Handle<AudioSource>>);

/// The amount of time to spend fading the music in and out.
pub const MUSIC_FADE_DURATION: Duration = Duration::from_millis(500);

pub const MUSIC_VOLUME: f64 = 0.1;

/// System that plays music according to the game mode.
pub(super) fn music_system(
    meta: Root<GameMeta>,
    mut audio: ResMut<AudioCenter>,
    mut shuffled_fight_music: ResMutInit<ShuffledPlaylist>,
    mut music_state: ResMutInit<MusicState>,
    sessions: Res<Sessions>,
) {
    if shuffled_fight_music.is_empty() {
        let mut songs = meta.music.fight.clone();
        THREAD_RNG.with(|rng| rng.shuffle(&mut songs));
        **shuffled_fight_music = songs;
    }

    let tween = Tween {
        start_time: kira::StartTime::Immediate,
        duration: MUSIC_FADE_DURATION,
        easing: kira::tween::Easing::Linear,
    };
    let play_settings = StaticSoundSettings::default()
        .volume(MUSIC_VOLUME)
        .fade_in_tween(tween);

    // The lobby is always running, so this is effectively unconditional.
    if sessions.get(SessionNames::GAME).is_some() {
        if let MusicState::Fight { idx } = &mut *music_state {
            if let Some(PlaybackState::Stopped) = audio.music_state() {
                *idx = (*idx + 1) % shuffled_fight_music.len();
                audio.play_music_from_settings(shuffled_fight_music[*idx], play_settings, true);
            }
        } else if let Some(song) = shuffled_fight_music.get(0) {
            audio.play_music_from_settings(*song, play_settings, false);
            *music_state = MusicState::Fight { idx: 0 };
        }
    }
}
