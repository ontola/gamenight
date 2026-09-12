use crate::prelude::*;

/// Player spawner element
#[derive(HasSchema, Default, Debug, Clone, Copy)]
#[type_data(metadata_asset("player_spawner"))]
#[repr(C)]
pub struct PlayerSpawnerMeta;

pub fn game_plugin(game: &mut Game) {
    PlayerSpawnerMeta::register_schema();
    game.init_shared_resource::<AssetServer>();
}

pub fn session_plugin(session: &mut SessionBuilder) {
    session
        .stages
        .add_system_to_stage(CoreStage::First, hydrate)
        .add_system_to_stage(CoreStage::First, update);
}

/// Marker component for player spawners.
#[derive(Clone, Debug, HasSchema, Default)]
#[type_data(metadata_asset("player_spawner"))]
#[repr(C)]
pub struct PlayerSpawner;

/// Resource that stores the next spawner to use when spawning a player.
#[derive(Clone, Debug, HasSchema, Default)]
pub struct CurrentSpawner(pub usize);

#[derive(Clone, Debug, HasSchema, Default)]
pub struct LobbySpawnOrder(pub Vec<usize>);

#[derive(Clone, Debug, HasSchema, Default)]
pub struct LobbySpawnHistory(pub Vec<Option<Vec2>>);

fn choose_lobby_spawn(points: &[Vec3], previous: Option<Vec2>, occupied: &[Vec2], order: &[usize]) -> usize {
    let span=points.iter().map(|p|p.x).fold(f32::NEG_INFINITY,f32::max)
        - points.iter().map(|p|p.x).fold(f32::INFINITY,f32::min);
    let distance=(span*0.3).max(128.0);
    let clear=|point: Vec2| occupied.iter().all(|other|point.distance(*other)>=64.0);
    if let Some(&index)=order.iter().find(|&&i|clear(points[i].truncate()) && previous.is_none_or(|p|p.distance(points[i].truncate())>=distance)) { return index; }
    // Crowded/small maps still need a spawn: use the farthest authored point.
    order.iter().copied().max_by(|&a,&b|{
        let score=|i:usize| previous.map_or(0.0,|p|p.distance_squared(points[i].truncate()));
        score(a).total_cmp(&score(b))
    }).unwrap_or(0)
}

fn shuffled_spawn_order(count: usize) -> Vec<usize> {
    use turborand::prelude::*;
    let rng = Rng::new();
    let mut remaining: Vec<_> = (0..count).collect();
    let mut order = Vec::with_capacity(count);
    while let Some(&chosen) = rng.sample(&remaining) {
        order.push(chosen);
        remaining.retain(|&index| index != chosen);
    }
    order
}

fn hydrate(
    entities: Res<Entities>,
    mut hydrated: CompMut<MapElementHydrated>,
    element_handles: Comp<ElementHandle>,
    assets: Res<AssetServer>,
    mut player_spawners: CompMut<PlayerSpawner>,
    mut spawner_manager: SpawnerManager,
) {
    let mut not_hydrated_bitset = hydrated.bitset().clone();
    not_hydrated_bitset.bit_not();
    not_hydrated_bitset.bit_and(element_handles.bitset());

    for entity in entities.iter_with_bitset(&not_hydrated_bitset) {
        let element_handle = element_handles.get(entity).unwrap();
        let element_meta = assets.get(element_handle.0);

        if let Ok(PlayerSpawner) = assets.get(element_meta.data).try_cast_ref() {
            hydrated.insert(entity, MapElementHydrated);
            player_spawners.insert(entity, PlayerSpawner);

            spawner_manager.create_grouped_spawner(entity, vec![], &player_spawners, &entities);
        }
    }
}

fn update(
    mut commands: Commands,
    player_layers: Comp<PlayerLayers>,
    mut entities: ResMutInit<Entities>,
    mut current_spawner: ResMutInit<CurrentSpawner>,
    mut lobby_order: ResMutInit<LobbySpawnOrder>,
    mut spawn_history: ResMutInit<LobbySpawnHistory>,
    lobby: ResMutInit<crate::core::scoring::LobbyMode>,
    player_spawners: Comp<PlayerSpawner>,
    mut player_indexes: CompMut<PlayerIdx>,
    mut transforms: CompMut<Transform>,
    player_inputs: Res<MatchInputs>,
    mut spawner_manager: SpawnerManager,
) {
    if lobby.0 {
        for (entity, (index, _)) in entities.iter_with((&player_indexes, &player_layers)) {
            if !player_inputs.players[index.0 as usize].active {
                commands.add(PlayerCommand::despawn(entity));
            }
        }
    }
    let alive_players = entities
        .iter_with(&player_indexes)
        .map(|(_ent, pidx)| pidx.0)
        .collect::<Vec<_>>();
    spawn_history.0.resize(MAX_PLAYERS as usize,None);
    let mut occupied=Vec::new();
    for (_, (index,transform)) in entities.iter_with((&player_indexes,&transforms)) {
        spawn_history.0[index.0 as usize]=Some(transform.translation.truncate());
        occupied.push(transform.translation.truncate());
    }
    let spawn_points = entities
        .iter_with((&player_spawners, &transforms))
        .map(|(_ent, (_spawner, transform))| transform.translation)
        .collect::<Vec<_>>();

    if lobby.0 && lobby_order.0.len() != spawn_points.len() {
        lobby_order.0 = shuffled_spawn_order(spawn_points.len());
    }

    // For every player
    for i in 0..MAX_PLAYERS {
        let player = &player_inputs.players[i as usize];

        // If the player is active, but not alive
        if player.active && !alive_players.contains(&i) {
            // Increment the spawner index
            current_spawner.0 += 1;
            current_spawner.0 %= spawn_points.len().max(1);

            let index = if lobby.0 {
                lobby_order.0=shuffled_spawn_order(spawn_points.len());
                choose_lobby_spawn(&spawn_points,spawn_history.0[i as usize],&occupied,&lobby_order.0)
            } else { current_spawner.0 };
            let Some(mut spawn_point) = spawn_points.get(index).copied() else {
                return;
            };

            // Make sure each player spawns at a different z level ( give enough room for 10 players
            // to fit between map layers )
            spawn_point.z += i as f32 * MAP_LAYERS_GAP_DEPTH / 10.0;

            let player_ent = entities.create();
            player_indexes.insert(player_ent, PlayerIdx(i));
            transforms.insert(player_ent, Transform::from_translation(spawn_point));
            spawn_history.0[i as usize]=Some(spawn_point.truncate());
            occupied.push(spawn_point.truncate());

            spawner_manager.insert_spawned_entity_into_grouped_spawner(
                player_ent,
                &player_spawners,
                &entities,
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn respawn_avoids_death_position_and_occupied_points() {
        let points=vec![Vec3::new(0.,0.,0.),Vec3::new(100.,0.,0.),Vec3::new(400.,0.,0.),Vec3::new(800.,0.,0.)];
        assert_eq!(choose_lobby_spawn(&points,Some(Vec2::ZERO),&[Vec2::new(400.,0.)],&[0,1,2,3]),3);
        assert_eq!(choose_lobby_spawn(&points,Some(Vec2::ZERO),&[],&[2,3,0,1]),2);
        assert_eq!(choose_lobby_spawn(&points,Some(Vec2::ZERO),&[],&[3,2,0,1]),3);
        assert_eq!(choose_lobby_spawn(&points[..2],Some(Vec2::ZERO),&[],&[0,1]),1);
        assert_eq!(choose_lobby_spawn(&[],None,&[],&[]),0);
    }
    #[test]
    fn lobby_spawns_are_distinct_safe_points_and_vary() {
        let mut seen = std::collections::HashSet::new();
        for _ in 0..64 {
            let order = shuffled_spawn_order(4);
            seen.insert(order.clone());
            let mut sorted = order;
            sorted.sort_unstable();
            assert_eq!(sorted, vec![0, 1, 2, 3]);
        }
        assert!(seen.len() > 1);
        assert!(shuffled_spawn_order(0).is_empty());
    }
}
