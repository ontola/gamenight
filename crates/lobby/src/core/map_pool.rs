use crate::prelude::*;

#[derive(Clone, Debug, HasSchema)]
#[schema(no_default)]
pub struct MapPool {
    pub maps: Vec<Handle<MapMeta>>,
    pub current_map: Handle<MapMeta>,
}

impl MapPool {
    /// Convert to [`MapPoolNetwork`] which is serializable for replication.
    pub fn into_network(&self, assets: &AssetServer) -> MapPoolNetwork {
        MapPoolNetwork {
            maps: self.maps.iter().map(|h| h.network_handle(assets)).collect(),
            current_map: self.current_map.network_handle(assets),
        }
    }

    /// Convert [`MapPoolNetwork`] into a [`MapPool`]
    pub fn from_network(map_pool: MapPoolNetwork, assets: &AssetServer) -> MapPool {
        MapPool {
            maps: map_pool
                .maps
                .iter()
                .map(|h| h.into_handle(assets))
                .collect(),
            current_map: map_pool.current_map.into_handle(assets),
        }
    }

    /// Make a `MapPool` consisting of single map.
    pub fn from_single_map(map: Handle<MapMeta>) -> Self {
        Self {
            maps: vec![map],
            current_map: map,
        }
    }

    /// Construct `MapPool` from a slice of maps, or `None` if there are none.
    ///
    /// A pool has to name a current map, so an empty slice has no valid
    /// representation. This returns `None` rather than indexing, because since
    /// the lobby stopped shipping combat arenas `stable_maps` is legitimately
    /// empty and this used to panic on `maps[0]`.
    pub fn from_slice(maps: &[Handle<MapMeta>]) -> Option<Self> {
        Some(Self {
            maps: maps.into(),
            current_map: *maps.first()?,
        })
    }

    /// Randomize current map. Updates `curent_map` on self and returns `Handle<MapMeta>`.
    pub fn randomize_current_map(&mut self, rng: &GlobalRng) -> Handle<MapMeta> {
        self.current_map = *rng.sample(&self.maps).unwrap();
        self.current_map
    }

    /// Return a random map handle from pool
    pub fn get_random_map(&self, rng: &GlobalRng) -> Handle<MapMeta> {
        *rng.sample(&self.maps).unwrap()
    }
}

#[derive(Serialize, Deserialize)]
pub struct MapPoolNetwork {
    pub maps: Vec<NetworkHandle<MapMeta>>,
    pub current_map: NetworkHandle<MapMeta>,
}
