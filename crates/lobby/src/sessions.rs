use crate::{core::LobbyDefaultMatchRunner, prelude::*, ui::scoring::ScoringMenuState};

pub struct SessionNames;
impl SessionNames {
    pub const AUDIO: &'static str = DEFAULT_BONES_AUDIO_SESSION;
    pub const DEBUG: &'static str = "debug";
    pub const GAME: &'static str = "game";
    #[cfg(not(target_arch = "wasm32"))]
    pub const GAMENIGHT: &'static str = "gamenight";
    pub const PROFILER: &'static str = "profiler";
    pub const PRESS_START: &'static str = "press_start";
    pub const SCORING: &'static str = "scoring";
    pub const NOTIFICATION: &'static str = "notification";
}

pub trait SessionExt {
    fn end_game(&mut self);
    /// Optionally provide map_pool to restart game with. If not provided,
    /// current game's [`MapPool`] will be used.
    fn restart_game(&mut self, map_pool: Option<MapPool>, reset_score: bool);
    fn start_game(&mut self, match_plugin: crate::core::MatchPlugin);
}

impl SessionExt for Sessions {
    fn end_game(&mut self) {
        self.delete(SessionNames::GAME);

        // Make sure that scoring menu closed if was open
        if let Some(scoring_session) = self.get_mut(SessionNames::SCORING) {
            if let Some(mut state) = scoring_session.world.get_resource_mut::<ScoringMenuState>() {
                state.active = false;
            }
        }
    }

    #[track_caller]
    fn restart_game(&mut self, map_pool: Option<MapPool>, reset_score: bool) {
        if let Some((existing_map_pool, player_info, plugins, mut session_runner, score)) =
            self.get_mut(SessionNames::GAME).map(|session| {
                let existing_map_pool = (*session.world.resource::<MapPool>()).clone();
                let match_inputs = session.world.resource::<MatchInputs>();
                let score = (*session.world.resource::<MatchScore>()).clone();

                // Take ownership of session runner (we want to preserve socket and such for network runner)
                // by swapping a dummy one with session.
                let mut session_runner: Box<dyn SessionRunner> =
                    Box::<LobbyDefaultMatchRunner>::default();
                std::mem::swap(&mut session.runner, &mut session_runner);

                (
                    existing_map_pool,
                    match_inputs.players.clone(),
                    session.world.resource::<LuaPlugins>().0.clone(),
                    session_runner,
                    score,
                )
            })
        {
            self.end_game();

            // Reset session runner
            session_runner.restart_session();

            let map_pool = map_pool.unwrap_or(existing_map_pool);
            let score = if reset_score {
                MatchScore::default()
            } else {
                score
            };

            self.create_with(SessionNames::GAME, |builder: &mut SessionBuilder| {
                builder.install_plugin(crate::core::MatchPlugin {
                    maps: map_pool,
                    player_info,
                    plugins,
                    session_runner,
                    score,
                    lobby_mode: false,
                });
            });
        } else {
            panic!("Cannot restart game when game is not running");
        }
    }

    fn start_game(&mut self, match_plugin: crate::core::MatchPlugin) {
        self.create_with(SessionNames::GAME, |builder: &mut SessionBuilder| {
            builder.install_plugin(match_plugin);
        });
    }
}
