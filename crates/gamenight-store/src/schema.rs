//! Typed progress: games that publish a save schema.
//!
//! A game can describe its `save_player_data` JSON with a JSON Schema
//! (`save-schema.json` next to `gamenight.json`). Publishing it makes an
//! Atomic ontology for the game on the hub: one content-addressed Property
//! per field, plus a Lens for each field a later version renamed or retyped.
//! The hub keeps these in its schema drive, which every account drive points
//! to ([`SCHEMAS`]), so hosts and phones sync it next to the account.
//!
//! With the schema here, the store keeps each known top-level field of a
//! game's data as its own typed property, which Atomic merges per field.
//! Fields the schema does not know stay in the JSON blob (`ns/data`), as do
//! all fields of games without a schema. Games see none of this: they save
//! and load the same JSON as before.
//!
//! When a game renames a field, its lens makes data saved under the old
//! name show under the new one (and back, for hosts that still run the
//! older build), at read time, without rewriting anything that was signed.

use std::collections::{BTreeMap, HashMap};

use atomic_lib::{datatype::match_datatype, urls, Db, Resource, Storelike, Value};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value as Json};

use crate::{atomic, Result};

/// The hub's record of one game's published schema.
pub const GAME_SCHEMA: &str = "https://gamenight.ontola.io/ns/GameSchema";
/// On a [`GAME_SCHEMA`]: the game id.
pub const SCHEMA_GAME: &str = "https://gamenight.ontola.io/ns/game";
/// On a [`GAME_SCHEMA`]: the current fields, as [`Fields`] JSON.
pub const SCHEMA_FIELDS: &str = "https://gamenight.ontola.io/ns/saveFields";
/// On an account drive: the hub's schema drive.
pub const SCHEMAS: &str = "https://gamenight.ontola.io/ns/schemas";

/// One field of a game's saved data.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Field {
    /// The `atomic:prop:` Property it is kept under.
    pub property: String,
    /// The Property's datatype.
    pub datatype: String,
}

/// A game's current fields: top-level key -> field.
pub type Fields = BTreeMap<String, Field>;

/// Every published schema in `drive`: game id -> fields.
pub async fn load(db: &Db, drive: &str) -> Result<HashMap<String, Fields>> {
    let mut schemas = HashMap::new();
    for resource in db
        .get_children(drive, Some(GAME_SCHEMA))
        .await
        .map_err(atomic)?
    {
        let (Ok(game), Ok(fields)) = (resource.get(SCHEMA_GAME), resource.get(SCHEMA_FIELDS))
        else {
            continue;
        };
        match serde_json::from_str::<Fields>(&fields.to_string()) {
            Ok(fields) => {
                schemas.insert(game.to_string(), fields);
            }
            Err(error) => tracing::warn!(%error, game = %game, "unreadable save schema"),
        }
    }
    Ok(schemas)
}

/// The schema drive an account drive points to, if the hub set one.
pub async fn schema_drive_of(db: &Db, drive: &str) -> Option<String> {
    let resource = db.get_resource(&drive.into()).await.ok()?;
    resource.get(SCHEMAS).ok().map(|v| v.to_string())
}

/// A value as `datatype` keeps it. `None` when it does not fit.
fn to_value(json: &Json, datatype: &str) -> Option<Value> {
    if datatype == urls::JSON {
        return Some(Value::Json(json.clone()));
    }
    let datatype = match_datatype(datatype);
    atomic_lib::lens::json_to_value(json, Some(&datatype))
}

fn to_json(value: &Value) -> Option<Json> {
    match value {
        Value::Json(json) => Some(json.clone()),
        other => atomic_lib::lens::value_to_json(other),
    }
}

/// Split a game's data into typed properties and what stays in the blob.
/// Data that is not a JSON object stays whole in the blob.
pub fn split(data: &Json, fields: &Fields) -> (Vec<(String, Value)>, Json) {
    let Json::Object(object) = data else {
        return (Vec::new(), data.clone());
    };
    let mut typed = Vec::new();
    let mut rest = Map::new();
    for (key, value) in object {
        match fields
            .get(key)
            .and_then(|f| to_value(value, &f.datatype).map(|v| (f, v)))
        {
            Some((field, value)) => typed.push((field.property.clone(), value)),
            None => {
                rest.insert(key.clone(), value.clone());
            }
        }
    }
    (typed, Json::Object(rest))
}

/// The game's data as it saved it: the blob with the typed fields put back.
/// Lenses have already been applied to `resource` when it was read.
pub fn join(resource: &Resource, blob: Option<Json>, fields: &Fields) -> Option<Json> {
    let mut object = match blob {
        Some(Json::Object(object)) => object,
        Some(other) => return Some(other),
        None => Map::new(),
    };
    let mut any = false;
    for (key, field) in fields {
        if let Some(json) = resource.get(&field.property).ok().and_then(to_json) {
            object.insert(key.clone(), json);
            any = true;
        }
    }
    (any || !object.is_empty()).then_some(Json::Object(object))
}

/// The properties a write of `typed` makes stale: the other end of every
/// lens on a property being written, so an older build that reads the old
/// name gets the new value through the lens instead of its own last one.
pub fn superseded(db: &Db, typed: &[(String, Value)]) -> Vec<String> {
    let lenses = db.lenses();
    let mut stale = Vec::new();
    for (property, _) in typed {
        let property = atomic_lib::identifiers::canonicalize_scheme(property);
        for lens in lenses.lenses_for(&property) {
            let other = if lens.to == property {
                &lens.from
            } else {
                &lens.to
            };
            if !stale.contains(other) {
                stale.push(other.clone());
            }
        }
    }
    stale
}

/// True for an `atomic:prop:` property: a field some game's schema made.
pub fn is_field(property: &str) -> bool {
    atomic_lib::identifiers::is_prop_id(property)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::sync::tests::{account_drive, serve};
    use crate::Store;
    use atomic_lib::commit::{CommitBuilder, CommitOpts};
    use atomic_lib::schema::json_schema::{
        ensure_ontology, ontology_from_json_schema_str, ImportOptions,
    };
    use gamenight_core::SavedPlayerData;
    use serde_json::json;

    /// What the hub does when a game publishes `schema`: the ontology, a
    /// rename lens per `(old property, new field)`, and the game's record.
    pub(crate) async fn publish(
        hub: &Db,
        drive: &str,
        game: &str,
        schema: &str,
        renames: &[(&str, &str)],
    ) -> Fields {
        let agent = hub.get_default_agent().unwrap();
        let plan = ontology_from_json_schema_str(
            schema,
            &ImportOptions {
                shortname: Some(game.into()),
            },
        )
        .unwrap();
        let ensured = ensure_ontology(hub, &drive.into(), &plan, &agent)
            .await
            .unwrap();
        let fields: Fields = plan.classes[0]
            .properties
            .iter()
            .map(|p| {
                (
                    p.shortname.clone(),
                    Field {
                        property: ensured.properties[&p.shortname].clone(),
                        datatype: p.datatype.clone(),
                    },
                )
            })
            .collect();
        for (from, to) in renames {
            let transform = json!({"op": "rename"});
            let to = &fields[*to].property;
            let id = atomic_lib::lens::lens_id(from, to, &transform).unwrap();
            let mut b = CommitBuilder::new(id.as_str().into());
            b.is_genesis = true;
            b.set(urls::IS_A.into(), Value::from(vec![urls::LENS.to_string()]));
            b.set(
                urls::PARENT.into(),
                Value::AtomicUrl(ensured.ontology.as_str().into()),
            );
            // In the schema drive, so it syncs with the properties.
            b.set(urls::DRIVE_PROP.into(), Value::AtomicUrl(drive.into()));
            b.set(urls::LENS_FROM.into(), Value::AtomicUrl((*from).into()));
            b.set(urls::LENS_TO.into(), Value::AtomicUrl(to.as_str().into()));
            b.set(urls::LENS_TRANSFORM.into(), Value::Json(transform));
            let commit = b
                .sign(&agent, hub, &Resource::new(id.clone()))
                .await
                .unwrap();
            let opts = CommitOpts {
                update_index: true,
                ..CommitOpts::no_validations_no_index()
            };
            hub.apply_commit(commit, &opts).await.unwrap();
        }
        let json = Value::String(serde_json::to_string(&fields).unwrap());
        match hub
            .get_children(drive, Some(GAME_SCHEMA))
            .await
            .unwrap()
            .into_iter()
            .find(|r| r.get(SCHEMA_GAME).is_ok_and(|g| g.to_string() == game))
        {
            Some(mut record) => {
                record.set_unsafe(SCHEMA_FIELDS.into(), json).unwrap();
                record.save_locally(hub).await.unwrap();
            }
            None => {
                hub.create_resource(
                    GAME_SCHEMA,
                    drive,
                    game,
                    Some(vec![
                        (SCHEMA_GAME, Value::String(game.into())),
                        (SCHEMA_FIELDS, json),
                    ]),
                )
                .await
                .unwrap();
            }
        }
        fields
    }

    /// The hub's schema drive: anyone may read it.
    pub(crate) async fn schema_drive(hub: &Db, account_drives: &[&str]) -> String {
        let drive = hub.create_drive("GameNight schemas").await.unwrap();
        let mut resource = hub.get_resource(&drive.as_str().into()).await.unwrap();
        let owner = hub.get_default_agent().unwrap().subject.to_string();
        resource
            .set_unsafe(
                urls::READ.into(),
                Value::ResourceArray(vec![owner.into(), urls::PUBLIC_AGENT.to_string().into()]),
            )
            .unwrap();
        hub.add_resource_opts(&resource, false, true, true)
            .await
            .unwrap();
        for account in account_drives {
            let mut resource = hub.get_resource(&(*account).into()).await.unwrap();
            resource
                .set_unsafe(SCHEMAS.into(), Value::AtomicUrl(drive.as_str().into()))
                .unwrap();
            hub.add_resource_opts(&resource, false, true, true)
                .await
                .unwrap();
        }
        drive
    }

    const V1: &str = r#"{
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$defs": { "progress": { "type": "object", "properties": {
            "wins": { "type": "integer" },
            "unlocked": { "type": "array", "items": { "type": "string" } }
        } } }
    }"#;
    const V2: &str = r#"{
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$defs": { "progress": { "type": "object", "properties": {
            "victories": { "type": "integer" },
            "unlocked": { "type": "array", "items": { "type": "string" } }
        } } }
    }"#;

    fn temp() -> std::path::PathBuf {
        std::env::temp_dir().join(format!("gamenight-schema-{}", uuid::Uuid::new_v4()))
    }

    #[tokio::test]
    async fn typed_progress_syncs_and_follows_a_renamed_field() {
        let hub = Db::init_temp("hub-schema").await.unwrap();
        hub.setup("Hub").await.unwrap();
        let (phone_dir, host_dir) = (temp(), temp());
        let mut phone = Store::open(&phone_dir).await.unwrap();
        let mut host = Store::open(&host_dir).await.unwrap();
        let drive = account_drive(&hub, &[&phone.agent().unwrap(), &host.agent().unwrap()]).await;
        let schemas = schema_drive(&hub, &[&drive]).await;
        let v1 = publish(&hub, &schemas, "hexstead", V1, &[]).await;
        let origin = "https://hub.test";
        for store in [&mut phone, &mut host] {
            store
                .sync(&mut serve(hub.clone()), origin, &drive)
                .await
                .unwrap();
            store.link("account:ada", &drive).await.unwrap();
            store
                .sync_schemas(&mut serve(hub.clone()), origin)
                .await
                .unwrap();
            assert_eq!(store.schema("hexstead"), Some(&v1));
        }

        // The host keeps the known fields typed, the rest in the blob.
        let saved = SavedPlayerData {
            data: json!({"wins": 3, "unlocked": ["fire"], "hat": "red"}),
            revision: 1,
        };
        host.put_data("account:ada", "hexstead", &saved)
            .await
            .unwrap();
        let subject = host.records[&("account:ada".into(), "hexstead".into())].clone();
        let record = host
            .db
            .get_resource(&subject.as_str().into())
            .await
            .unwrap();
        assert!(matches!(
            record.get(&v1["wins"].property).unwrap(),
            Value::Integer(3)
        ));
        assert_eq!(
            record.get(crate::DATA).unwrap().to_string(),
            r#"{"hat":"red"}"#
        );
        assert_eq!(
            host.load().await.unwrap().data["account:ada"]["hexstead"],
            saved
        );

        // The phone gets the same data back.
        host.sync(&mut serve(hub.clone()), origin, &drive)
            .await
            .unwrap();
        phone
            .sync(&mut serve(hub.clone()), origin, &drive)
            .await
            .unwrap();
        assert_eq!(
            phone.load().await.unwrap().data["account:ada"]["hexstead"],
            saved
        );

        // A new version renames wins to victories, with a lens. Data saved
        // under the old name reads under the new one after the next sync.
        let v2 = publish(
            &hub,
            &schemas,
            "hexstead",
            V2,
            &[(&v1["wins"].property, "victories")],
        )
        .await;
        let (_, changed) = phone
            .sync_schemas(&mut serve(hub.clone()), origin)
            .await
            .unwrap();
        assert!(changed.contains(&("account:ada".into(), "hexstead".into())));
        assert_eq!(phone.schema("hexstead"), Some(&v2));
        let data = &phone.load().await.unwrap().data["account:ada"]["hexstead"];
        assert_eq!(
            data.data,
            json!({"victories": 3, "unlocked": ["fire"], "hat": "red"})
        );

        // Saving under the new name drops the old value, so a host still on
        // the older build reads the new one through the lens.
        let newer = SavedPlayerData {
            data: json!({"victories": 5, "unlocked": ["fire"], "hat": "red"}),
            revision: 2,
        };
        phone
            .put_data("account:ada", "hexstead", &newer)
            .await
            .unwrap();
        let subject = phone.records[&("account:ada".into(), "hexstead".into())].clone();
        let record = phone
            .db
            .get_resource(&subject.as_str().into())
            .await
            .unwrap();
        assert!(matches!(
            record.get(&v1["wins"].property).unwrap(),
            Value::Integer(5)
        ));
        assert!(matches!(
            record.get(&v2["victories"].property).unwrap(),
            Value::Integer(5)
        ));

        // And it is still so after a restart, without the hub.
        drop(phone);
        let phone = Store::open(&phone_dir).await.unwrap();
        let data = &phone.load().await.unwrap().data["account:ada"]["hexstead"];
        assert_eq!(data.data["victories"], 5);
        let _ = std::fs::remove_dir_all(phone_dir);
        let _ = std::fs::remove_dir_all(host_dir);
    }
}
