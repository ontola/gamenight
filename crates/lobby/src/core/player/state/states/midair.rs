use super::*;

pub static ID: Lazy<Ustr> = Lazy::new(|| ustr("core::midair"));

pub fn install(session: &mut SessionBuilder) {
    PlayerState::add_player_state_transition_system(session, player_state_transition);
    PlayerState::add_player_state_update_system(session, handle_player_state);
    PlayerState::add_player_state_update_system(session, use_drop_or_grab_items_system(*ID));
}

pub fn player_state_transition(
    entities: Res<Entities>,
    player_inputs: Res<MatchInputs>,
    player_indexes: Comp<PlayerIdx>,
    assets: Res<AssetServer>,
    mut player_states: CompMut<PlayerState>,
    bodies: Comp<KinematicBody>,
    mut audio_center: ResMut<AudioCenter>,
) {
    for (_ent, (player_idx, player_state, body)) in
        entities.iter_with((&player_indexes, &mut player_states, &bodies))
    {
        let meta_handle = player_inputs.players[player_idx.0 as usize].selected_player;
        let meta = assets.get(meta_handle);
        let control = &player_inputs.players[player_idx.0 as usize].control;
        if player_state.current != *ID {
            continue;
        }

        if body.is_on_ground {
            // Play land sound
            audio_center.play_sound(meta.sounds.land, meta.sounds.land_volume);
            // Switch to idle state
            player_state.current = *idle::ID;
        } else if control.ragdoll_just_pressed {
            // TODO audio
            player_state.current = *ragdoll::ID;
        }
    }
}

/// How much of a normal jump a player gets off a wall. A shade under a full
/// one: kicking off a surface is a recovery, not a better staircase than the
/// floor.
const WALL_JUMP_LIFT: f32 = 0.92;

/// How hard a wall jump throws you away from what you kicked off, as a share
/// of full air speed. Enough that you clear the wall and can't cling to the
/// same one twice without steering back into it.
const WALL_JUMP_PUSH: f32 = 1.15;

/// How fast you slide down a wall you're pressed against, in world units per
/// second. Slow enough to give you time to decide, fast enough that hanging
/// there isn't a way to sit out a fight.
const WALL_SLIDE_SPEED: f32 = 130.0;

/// Whether there's something solid immediately to one side of this body —
/// `dir` is -1 for left, 1 for right.
///
/// Asked with a thin probe beside the body rather than the body's own shape,
/// because a body resting on the ground already overlaps the tile beneath it
/// and would report a wall on both sides. Uses the same test the movement
/// code does, so it sees map tiles and lobby furniture alike: the jukebox and
/// the sign-in cabinet are things you can kick off, and a player who has just
/// worked that out is not going to accept "but they're not tiles".
fn wall_beside(
    collision_world: &CollisionWorld,
    transform: &Transform,
    body: &KinematicBody,
    dir: f32,
) -> bool {
    let box_ = body.bounding_box(*transform);
    let height = (box_.max.y - box_.min.y - 12.0).max(4.0);
    let mut probe = *transform;
    probe.translation.x = if dir > 0.0 {
        box_.max.x + 3.0
    } else {
        box_.min.x - 3.0
    };
    probe.translation.y = (box_.min.y + box_.max.y) / 2.0;
    collision_world.tile_collision(
        probe,
        ColliderShape::Rectangle {
            size: vec2(4.0, height),
        },
    ) == TileCollisionKind::Solid
}

pub fn handle_player_state(
    entities: Res<Entities>,
    player_inputs: Res<MatchInputs>,
    player_indexes: Comp<PlayerIdx>,
    player_states: Comp<PlayerState>,
    assets: Res<AssetServer>,
    collision_world: CollisionWorld,
    time: Res<Time>,
    transforms: Comp<Transform>,
    mut sprites: CompMut<AtlasSprite>,
    mut animations: CompMut<AnimationBankSprite>,
    mut bodies: CompMut<KinematicBody>,
    mut audio_center: ResMut<AudioCenter>,
) {
    let players = entities.iter_with((
        &player_states,
        &player_indexes,
        &transforms,
        &mut animations,
        &mut sprites,
        &mut bodies,
    ));
    for (_player_ent, (player_state, player_idx, transform, animation, sprite, body)) in players {
        if player_state.current != *ID {
            continue;
        }
        let meta_handle = player_inputs.players[player_idx.0 as usize].selected_player;
        let meta = assets.get(meta_handle);
        let control = &player_inputs.players[player_idx.0 as usize].control;

        // Which wall, if any, is within kicking distance. Only checked on the
        // side you're actually heading into, so drifting past a wall doesn't
        // stick you to it.
        let wall = [-1.0, 1.0]
            .into_iter()
            .find(|dir| wall_beside(&collision_world, transform, body, *dir));

        if let Some(dir) = wall {
            let into_wall = control.move_direction.x * dir > 0.0;
            if control.jump_just_pressed {
                audio_center.play_sound(meta.sounds.jump, meta.sounds.jump_volume);
                body.velocity.y = meta.stats.jump_speed * WALL_JUMP_LIFT;
                body.velocity.x = -dir * meta.stats.air_speed * WALL_JUMP_PUSH;
            } else if into_wall && body.velocity.y < 0.0 {
                // Pressed against it and falling: slide, so there's a moment
                // to press jump rather than a frame.
                body.velocity.y = body.velocity.y.max(-WALL_SLIDE_SPEED);
            }
        }

        if body.velocity.y > 0.0 {
            animation.current = "rise".into();
        } else {
            animation.current = "fall".into();
        }

        // Releasing jump cuts the rise; holding never changes falling speed.
        body.velocity.y = jump_release_velocity(body.velocity.y, body.gravity, time.delta_seconds(), control.jump_pressed);

        // Walk in movement direction
        body.velocity.x += meta.stats.accel_air_speed * control.move_direction.x;
        if control.move_direction.x.is_sign_positive() {
            body.velocity.x = body.velocity.x.min(meta.stats.air_speed);
        } else {
            body.velocity.x = body.velocity.x.max(-meta.stats.air_speed);
        }

        if control.move_direction.x == 0.0 {
            if body.velocity.x.is_sign_positive() {
                body.velocity.x = (body.velocity.x - meta.stats.slowdown).max(0.0);
            } else {
                body.velocity.x = (body.velocity.x + meta.stats.slowdown).min(0.0);
            }
        }

        // Fall through platforms
        body.fall_through = control.move_direction.y < -0.5 && control.jump_just_pressed;

        // Point in movement direction
        if control.move_direction.x > 0.0 {
            sprite.flip_x = false;
        } else if control.move_direction.x < 0.0 {
            sprite.flip_x = true;
        }
    }
}

fn jump_release_velocity(velocity: f32, gravity: f32, dt: f32, held: bool) -> f32 {
    if held || velocity <= 0.0 { velocity } else { (velocity-gravity*2.0*dt).max(0.0) }
}
#[cfg(test)]
mod jump_tests {
    use super::jump_release_velocity;
    fn height(hold_frames:usize)->f32 {
        let (mut y,mut peak,mut velocity)=(0.0_f32,0.0_f32,660.0_f32);
        for frame in 0..120 {
            velocity=jump_release_velocity(velocity,2160.,1./60.,frame<hold_frames);
            y+=velocity/60.;peak=peak.max(y);velocity-=2160./60.;
        }
        peak
    }
    #[test]
    fn holding_longer_gives_measurably_more_height() {
        assert!(height(3)+10.<height(6));
        assert!(height(6)+15.<height(18));
        // Twenty frames is beyond the natural apex: holding cannot extend flight.
        assert_eq!(height(20),height(120));
    }
    #[test]
    fn holding_never_slows_falling() {
        assert_eq!(jump_release_velocity(-400.,2160.,1./60.,true),-400.);
        assert_eq!(jump_release_velocity(-400.,2160.,1./60.,false),-400.);
    }
}
