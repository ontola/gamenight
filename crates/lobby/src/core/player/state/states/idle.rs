use super::*;

pub static ID: Lazy<Ustr> = Lazy::new(|| ustr("core::idle"));

pub fn install(session: &mut SessionBuilder) {
    PlayerState::add_player_state_transition_system(session, player_state_transition);
    PlayerState::add_player_state_update_system(session, handle_player_state);
    PlayerState::add_player_state_update_system(session, use_drop_or_grab_items_system(*ID));
}

pub fn player_state_transition(
    entities: Res<Entities>,
    player_inputs: Res<MatchInputs>,
    player_indexes: Comp<PlayerIdx>,
    mut player_states: CompMut<PlayerState>,
    bodies: Comp<KinematicBody>,
) {
    for (_ent, (player_idx, player_state, body)) in
        entities.iter_with((&player_indexes, &mut player_states, &bodies))
    {
        if player_state.current != *ID {
            continue;
        }

        let control = &player_inputs.players[player_idx.0 as usize].control;

        if control.ragdoll_just_pressed {
            player_state.current = *ragdoll::ID;
        } else if !body.is_on_ground {
            player_state.current = *midair::ID;
        } else if control.move_direction.y < -0.5 {
            player_state.current = *crouch::ID;
        } else if control.move_direction.x != 0.0 {
            player_state.current = *walk::ID;
        }
    }
}

/// Presentation only: never changes controller state, velocity or collisions.
#[derive(Clone, HasSchema, Default)]
pub struct PresenceAnimation {
    sleeping: bool,
    wake_remaining: f32,
    input_grace: f32,
}
impl PresenceAnimation {
    fn step(&mut self, idle: bool, sleeping: bool, input: bool, dt: f32) -> Option<&'static str> {
        self.input_grace = (self.input_grace - dt).max(0.0);
        if input {
            self.input_grace = 1.0;
        }
        if !idle {
            self.sleeping = false;
            self.wake_remaining = 0.0;
            return None;
        }
        let sleeping = sleeping && self.input_grace == 0.0;
        if self.sleeping && !sleeping {
            self.wake_remaining = 4.0 / 9.0;
        }
        self.sleeping = sleeping;
        if sleeping {
            return Some("sleep");
        }
        if self.wake_remaining > 0.0 {
            self.wake_remaining = (self.wake_remaining - dt).max(0.0);
            return Some("wake");
        }
        Some("idle")
    }
}

pub fn handle_player_state(
    entities: Res<Entities>,
    player_inputs: Res<MatchInputs>,
    player_indexes: Comp<PlayerIdx>,
    player_states: Comp<PlayerState>,
    assets: Res<AssetServer>,
    mut sprites: CompMut<AnimationBankSprite>,
    mut bodies: CompMut<KinematicBody>,
    mut audio_center: ResMut<AudioCenter>,
    collision_world: CollisionWorld,
    slippery: CompMut<Slippery>,
    bridge: Option<Res<crate::gamenight::GameNightBridge>>,
    time: Res<Time>,
    mut presence: CompMut<PresenceAnimation>,
) {
    let players = entities.iter_with((&player_states, &player_indexes, &mut sprites, &mut bodies));
    for (player_ent, (player_state, player_idx, animation, body)) in players {
        let control = &player_inputs.players[player_idx.0 as usize].control;
        let has_input = control.move_direction != Vec2::ZERO
            || control.jump_pressed
            || control.shoot_pressed
            || control.grab_just_pressed
            || control.ragdoll_just_pressed
            || control.menu_start_pressed
            || control.menu_back_pressed
            || control.menu_confirm_pressed;
        if !presence.contains(player_ent) {
            presence.insert(player_ent, PresenceAnimation::default());
        }
        let desired = presence.get_mut(player_ent).unwrap().step(
            player_state.current == *ID,
            bridge
                .as_ref()
                .is_some_and(|bridge| bridge.seat_sleeping(player_idx.0)),
            has_input,
            time.delta_seconds(),
        );
        if player_state.current != *ID {
            continue;
        }
        let meta_handle = player_inputs.players[player_idx.0 as usize].selected_player;
        let meta = assets.get(meta_handle);

        // If this is the first frame of this state
        if player_state.age == 0 {
            // set our animation to idle
            animation.current = "idle".into();
        }

        if let Some(desired) = desired {
            if desired != "idle"
                || animation.current == ustr("sleep")
                || animation.current == ustr("wake")
            {
                animation.set_current(desired);
            }
        }
        let control = &player_inputs.players[player_idx.0 as usize].control;

        // If we are jumping
        if control.jump_just_pressed {
            // Play jump sound
            audio_center.play_sound(meta.sounds.jump, meta.sounds.jump_volume);

            // Move up
            body.velocity.y = meta.stats.jump_speed;
        }

        let mut slide_factor = 1.;
        for (slippery_ent, slippery_meta) in entities.iter_with(&slippery) {
            if collision_world
                .actor_collisions(player_ent)
                .contains(&slippery_ent)
            {
                slide_factor = 1. / slippery_meta.player_slide;
            }
        }

        // Since we are idling, slide
        if body.velocity.x != 0.0 {
            if body.velocity.x.is_sign_positive() {
                body.velocity.x = (body.velocity.x - meta.stats.slowdown * slide_factor).max(0.0);
            } else {
                body.velocity.x = (body.velocity.x + meta.stats.slowdown * slide_factor).min(0.0);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::PresenceAnimation;
    #[test]
    fn sleeping_holds_until_input_and_wake_returns_to_idle() {
        let mut animation = PresenceAnimation::default();
        assert_eq!(animation.step(true, true, false, 0.016), Some("sleep"));
        assert_eq!(animation.step(true, true, false, 2.0), Some("sleep"));
        assert_eq!(animation.step(true, true, true, 0.016), Some("wake"));
        assert_eq!(animation.step(true, false, false, 0.5), Some("wake"));
        assert_eq!(animation.step(true, false, false, 0.016), Some("idle"));
    }
    #[test]
    fn movement_interrupts_sleep_instantly_without_waiting_for_host() {
        let mut animation = PresenceAnimation::default();
        animation.step(true, true, false, 0.016);
        assert_eq!(animation.step(false, true, true, 0.016), None);
        assert_eq!(animation.step(true, true, false, 0.016), Some("idle"));
    }
}
