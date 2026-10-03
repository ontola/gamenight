//! Unarmed attacks use their own hit counter, never instant-kill damage regions.
use crate::prelude::*;

pub const DURATION: f32 = 0.24;
const WINDUP: f32 = 0.06;
const COOLDOWN: f32 = 0.32;

#[derive(Clone, Default, HasSchema)]
pub struct Punch {
    pub remaining: f32,
    pub direction: f32,
    cooldown: f32,
    struck: bool,
    hits: HitWindow,
    knockback: f32,
    push: f32,
}

#[derive(Clone, Default, HasSchema)]
struct HitWindow { ages: [f32; 4], count: usize }
impl HitWindow {
    fn tick(&mut self, dt: f32) {
        for age in &mut self.ages[..self.count] { *age += dt; }
        let keep: Vec<_> = self.ages[..self.count].iter().copied().filter(|age| *age <= 2.).collect();
        self.count = keep.len();
        self.ages[..self.count].copy_from_slice(&keep);
    }
    fn hit(&mut self) -> bool {
        if self.count < 4 { self.ages[self.count] = 0.; self.count += 1; }
        self.count == 4
    }
}

pub fn install(session: &mut SessionBuilder) {
    session.add_system_to_stage(CoreStage::PostUpdate, update);
}

fn update(entities: Res<Entities>, time: Res<Time>, inputs: Res<MatchInputs>,
    indices: Comp<PlayerIdx>, states: Comp<PlayerState>, inventories: Comp<Inventory>,
    transforms: Comp<Transform>, sprites: Comp<AtlasSprite>, killed: Comp<PlayerKilled>,
    invincible: Comp<Invincibility>, collision: CollisionWorld,
    mut punches: CompMut<Punch>, mut bodies: CompMut<KinematicBody>, mut commands: Commands) {
    let dt = time.delta_seconds();
    let players: Vec<_> = entities.iter_with(&indices).collect();
    for (entity, _) in &players {
        if !punches.contains(*entity) { punches.insert(*entity, Punch::default()); }
        let punch = punches.get_mut(*entity).unwrap();
        punch.hits.tick(dt);
        punch.remaining = (punch.remaining-dt).max(0.);
        punch.cooldown = (punch.cooldown-dt).max(0.);
        punch.knockback = (punch.knockback-dt).max(0.);
        if punch.knockback > 0. {
            if let Some(body) = bodies.get_mut(*entity) { body.velocity.x = punch.push; }
        }
    }
    for (attacker, index) in &players {
        if killed.contains(*attacker) { continue; }
        let allowed = states.get(*attacker).is_some_and(|s|
            matches!(s.current.as_str(), "core::idle" | "core::walk" | "core::midair" | "core::crouch"));
        let unarmed = inventories.get(*attacker).is_some_and(|i| i.is_none());
        let Some(origin) = transforms.get(*attacker).map(|t| t.translation.xy()) else {continue;};
        let punch = punches.get_mut(*attacker).unwrap();
        if !allowed || !unarmed { punch.remaining = 0.; continue; }
        if inputs.players[index.0 as usize].control.shoot_just_pressed && punch.cooldown == 0. {
            punch.remaining = DURATION; punch.cooldown = COOLDOWN; punch.struck = false;
            punch.direction = if sprites.get(*attacker).is_some_and(|s| s.flip_x) { -1. } else { 1. };
        }
        if punch.remaining <= 0. || punch.struck || DURATION-punch.remaining < WINDUP {continue;}
        punch.struck = true; // One impact check per press, including a miss.
        let direction = punch.direction;
        let target = players.iter().filter_map(|(target, _)| {
            if target == attacker || killed.contains(*target) || invincible.contains(*target) {return None;}
            let pos = transforms.get(*target)?.translation.xy();
            let delta = pos-origin;
            if delta.x*direction < 0. || delta.x.abs() > 56. || delta.y.abs() > 28. {return None;}
            // Do not punch through solid map walls or furniture.
            if (1..8).any(|i| collision.tile_collision(
                Transform::from_translation((origin+delta*(i as f32/8.)).extend(0.)),
                ColliderShape::Rectangle {size:Vec2::splat(2.)}
            ) == TileCollisionKind::Solid) {return None;}
            Some((*target,delta.length_squared()))
        }).min_by(|a,b| a.1.total_cmp(&b.1));
        if let Some((target,_)) = target {
            let victim = punches.get_mut(target).unwrap();
            if victim.hits.hit() {
                commands.add(PlayerCommand::kill(target, Some(origin)));
            } else {
                victim.knockback = 0.12; victim.push = direction*180.;
                if let Some(body) = bodies.get_mut(target) {
                    body.velocity.x = victim.push;
                    body.velocity.y = body.velocity.y.max(70.);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn four_hits_within_two_seconds_knock_out() {
        let mut hits=HitWindow::default();
        for _ in 0..3 { assert!(!hits.hit()); hits.tick(0.5); }
        assert!(hits.hit());
    }
    #[test] fn older_hits_expire_individually() {
        let mut hits=HitWindow::default();
        assert!(!hits.hit()); hits.tick(1.);
        assert!(!hits.hit()); hits.tick(1.01);
        assert!(!hits.hit()); assert!(!hits.hit()); assert!(hits.hit());
    }
    #[test] fn isolated_punches_do_not_accumulate() {
        let mut hits=HitWindow::default();
        for _ in 0..20 { assert!(!hits.hit()); hits.tick(2.01); }
    }
}
