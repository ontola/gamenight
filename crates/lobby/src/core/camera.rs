//! Camera controller and parallax.

use crate::prelude::*;

/// Install this module.
pub fn install(session: &mut SessionBuilder) {
    session
        .stages
        .add_system_to_stage(CoreStage::Last, camera_controller);
    session
        .stages
        .add_system_to_stage(CoreStage::Last, camera_parallax);
}

/// A sprite that is spawned as a part of the parallax background.
#[derive(Clone, HasSchema, Default)]
pub struct ParallaxBackgroundSprite {
    /// The sprite with `idx` of `0` will be centered, with indexes increasing and decreasing
    /// representing repeated tiles to the right and left respectively.
    pub idx: i32,
    /// Information about the parallax layer it is a part of.
    pub meta: ParallaxLayerMeta,
}

/// A subject of the camera.
///
/// The camera will move and zoom to ensure that all subjects remain visible. Entities must also
/// have a `Transform` component and a `KinematicBody` component for this to work properly.
#[derive(Clone, Copy, Debug, Default, HasSchema)]
pub struct CameraSubject {
    /// A rectangle around the subject that is larger than the subject, and will always move to
    /// contain it. The camera will seek to contain this rectangle, instead of the subject itself.
    ///
    /// The advantage of this processing method is that the larger rect doesn't move as much as the
    /// subject, because, for instance, a player jumping up and down in place will still be inside
    /// of their camera rect, so the camera will not move around annoyingly.
    rect: Rect,
}

/// The state of the camera.
#[derive(Clone, Debug, HasSchema, Default)]
pub struct CameraState {
    /// Disables the default camera controller. Useful, for example, when taking over the camera
    /// from the editor.
    pub disable_controller: bool,
}

/// Implemenets the camera controller.
fn camera_controller(
    meta: Root<GameMeta>,
    entities: Res<Entities>,
    map: Res<LoadedMap>,
    mut cameras: CompMut<Camera>,
    mut camera_shakes: CompMut<CameraShake>,
    camera_states: Comp<CameraState>,
    mut camera_subjects: CompMut<CameraSubject>,
    transforms: Comp<Transform>,
    bodies: Comp<KinematicBody>,
    window: Res<Window>,
    lobby_mode: ResMutInit<crate::core::scoring::LobbyMode>,
) {
    let meta = &meta.core.camera;

    let Some((_ent, (camera, camera_shake, camera_state))) = entities
        .iter_with((&mut cameras, &mut camera_shakes, &camera_states))
        .next()
    else {
        return;
    };
    if camera_state.disable_controller {
        return;
    }

    // The hangout is a room, not a camera target formed by its occupants.
    // Seat changes rebuild subjects; using map bounds prevents join/leave zooms
    // and also keeps the empty lobby framed exactly like the occupied lobby.
    if lobby_mode.0 {
        let viewport = camera.viewport.option().map(|v| v.size.as_vec2()).unwrap_or(window.size);
        let map_size = map.grid_size.as_vec2() * map.tile_size;
        let (center, height) = lobby_frame(map_size, viewport);
        camera.size = CameraSize::FixedHeight(height);
        camera_shake.center.x = center.x;
        camera_shake.center.y = center.y;
        return;
    }

    // Update player camera rects
    for (_ent, (camera_subj, transform, body)) in
        entities.iter_with((&mut camera_subjects, &transforms, &bodies))
    {
        let camera_box_size = meta.player_camera_box_size;

        // Get the player's camera box
        let camera_box = &mut camera_subj.rect;

        // If it's not be initialized.
        if camera_box.min == Vec2::ZERO && camera_box.max == Vec2::ZERO {
            // Set it's size and position according to the player
            *camera_box = Rect::new(
                transform.translation.x,
                transform.translation.y,
                camera_box_size.x,
                camera_box_size.y,
            );
        }

        // Get the player's body rect
        let rect = body.bounding_box(*transform);

        // Push the camera rect just enough to contain the player's body rect
        if rect.min.x < camera_box.min.x {
            camera_box.min.x = rect.min.x;
            camera_box.max.x = camera_box.min.x + camera_box_size.x;
        }
        if rect.max.x > camera_box.max.x {
            camera_box.max.x = rect.max.x;
            camera_box.min.x = rect.max.x - camera_box_size.x;
        }
        if rect.min.y < camera_box.min.y {
            camera_box.min.y = rect.min.y;
            camera_box.max.y = camera_box.min.y + camera_box_size.y;
        }
        if rect.max.y > camera_box.max.y {
            camera_box.max.y = rect.max.y;
            camera_box.min.y = rect.max.y - camera_box_size.y;
        }
    }

    let viewport_size = camera
        .viewport
        .option()
        .map(|x| x.size.as_vec2())
        .unwrap_or(window.size);
    let viewport_aspect = viewport_size.x / viewport_size.y;
    let default_height = meta.default_height;
    let default_width = viewport_aspect * default_height;
    let camera_height = if let CameraSize::FixedHeight(height) = camera.size {
        height
    } else {
        400.0
    };
    let mut scale = camera_height / default_height;
    let map_size = map.grid_size.as_vec2() * map.tile_size;

    let mut min = Vec2::MAX;
    let mut max = Vec2::MIN;

    for CameraSubject { rect } in camera_subjects.iter_mut() {
        min = (rect.min - vec2(meta.border_left, meta.border_bottom))
            .min(min)
            .max(Vec2::ZERO);
        max = (rect.max + vec2(meta.border_right, meta.border_top)).max(max);
        max.x = max.x.min(map_size.x)
    }

    let camera_pos = &mut camera_shake.center;

    let subject_count = camera_subjects.iter().count();

    // With nobody in the room, show the room. Previously `min`/`max` were left
    // at their sentinels, so `size` came out negative and clamped to
    // `min_camera_size` — the camera sat zoomed right in on a corner of an
    // empty lobby, which is the least useful thing it could be looking at.
    let (mut middle_point, size) = if subject_count == 0 {
        (map_size * 0.5, map_size)
    } else {
        (
            Rect { min, max }.center(),
            (max - min).max(meta.min_camera_size),
        )
    };

    let rh = size.y / default_height;
    let rw = size.x / default_width;
    let r_target = if rh > rw { rh } else { rw };
    let r_diff = r_target - scale;
    if r_diff > 0.0 {
        scale += r_diff * meta.zoom_out_lerp_factor;
    } else {
        scale += r_diff * meta.zoom_in_lerp_factor;
    }

    // Keep camera above the map floor
    if middle_point.y - size.y / 2. < 0.0 {
        middle_point.y = size.y / 2.0;
    }

    let delta = camera_pos.truncate() - middle_point;
    let dist = delta * meta.move_lerp_factor;
    camera.size = CameraSize::FixedHeight(scale * default_height);
    *camera_pos -= dist.extend(0.0);
}

/// Fit the whole room with a small border, preserving geometry on any display.
fn lobby_frame(map_size: Vec2, viewport: Vec2) -> (Vec2, f32) {
    let aspect = viewport.x.max(1.0) / viewport.y.max(1.0);
    let padded = map_size + Vec2::splat(24.0);
    (map_size * 0.5, padded.y.max(padded.x / aspect))
}

#[cfg(test)]
mod lobby_camera_tests {
    use super::*;

    #[test]
    fn room_fits_wide_and_tall_windows_without_changing_its_center() {
        let room = Vec2::new(1200.0, 700.0);
        for viewport in [Vec2::new(1920.0, 1080.0), Vec2::new(800.0, 1200.0)] {
            let (center, height) = lobby_frame(room, viewport);
            assert_eq!(center, room * 0.5);
            assert!(height >= room.y + 24.0);
            assert!(height * viewport.x / viewport.y >= room.x + 23.99);
        }
    }

    #[test]
    fn minimized_window_has_a_finite_frame() {
        let (_, height) = lobby_frame(Vec2::new(1200.0, 700.0), Vec2::ZERO);
        assert!(height.is_finite() && height > 0.0);
    }
}

/// Implements the background layer parallax.
fn camera_parallax(
    entities: Res<Entities>,
    mut transforms: CompMut<Transform>,
    parallax_bg_sprites: Comp<ParallaxBackgroundSprite>,
    cameras: Comp<Camera>,
    map: Res<LoadedMap>,
) {
    // TODO: This constant represents that maximum camera-visible distance, and should be moved
    // somewhere more appropriate.
    const FAR_PLANE: f32 = 1000.0;

    let map_size = map.grid_size.as_vec2() * map.tile_size;

    let camera_transform = entities
        .iter_with((&transforms, &cameras))
        .next()
        .map(|x| x.1 .0)
        .copied()
        .unwrap();
    let camera_offset = map_size / 2.0 - camera_transform.translation.truncate();

    for (_ent, (transform, bg)) in entities.iter_with((&mut transforms, &parallax_bg_sprites)) {
        transform.scale.x = bg.meta.scale;
        transform.scale.y = bg.meta.scale;
        let display_size = transform.scale.truncate() * bg.meta.size;
        transform.translation.x = bg.idx as f32 * display_size.x;
        transform.translation.y = map_size.y / 2.0;
        transform.translation.z = -FAR_PLANE + 1.0 - bg.meta.depth / 100.0;
        transform.translation += bg.meta.offset.extend(1.0);

        transform.translation.x -= camera_offset.x * bg.meta.depth * map.background.speed.x;
        transform.translation.y += camera_offset.y * bg.meta.depth * map.background.speed.y;
    }
}
