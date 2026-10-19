//! The wire protocol as one JSON Schema: `contract/protocol.schema.json`.
//!
//! Every message, field and enum comes from the Rust types in this crate,
//! and `x-gamenight-constants` carries the constants other languages need
//! (protocol version, launch environment, avatar format, artwork limits).
//! `scripts/build-protocol.py` turns that file into the C, GDScript, JS,
//! Dart and Python bindings, so they cannot drift from this crate.
//!
//! A test fails when the committed file is stale. Rewrite it with
//! `GAMENIGHT_WRITE_SCHEMA=1 cargo test -p gamenight-protocol schema`, then run
//! `python3 scripts/build-protocol.py`.

use serde_json::{json, Value};

use crate::{artwork, avatar, guest_face};

/// The protocol schema, ready to pretty-print.
pub fn protocol_schema() -> Value {
    let mut generator = schemars::generate::SchemaSettings::draft2020_12().into_generator();
    let client = generator.subschema_for::<crate::ClientMessage>();
    let server = generator.subschema_for::<crate::ServerMessage>();
    // Flattened into SettingSpec, so named here to keep its kinds listed.
    generator.subschema_for::<crate::SettingKind>();
    let mut defs = generator.take_definitions(true);
    defs.sort_keys();
    json!({
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$id": "https://github.com/ontola/gamenight/blob/main/contract/protocol.schema.json",
        "title": "GameNight wire protocol",
        "description": "One JSON object per WebSocket text frame, tagged by \"type\". Generated from crates/gamenight-protocol; do not edit.",
        "anyOf": [client, server],
        "x-gamenight-messages": {
            "client": client,
            "server": server,
        },
        "x-gamenight-constants": constants(),
        "$defs": defs,
    })
}

fn constants() -> Value {
    json!({
        "protocol": {
            "PROTOCOL_VERSION": crate::PROTOCOL_VERSION,
            "GODOT_SDK_VERSION": crate::GODOT_SDK_VERSION,
            "DEFAULT_ADDR": crate::DEFAULT_ADDR,
            "DEFAULT_WEB_PORT": crate::DEFAULT_WEB_PORT,
        },
        "env": {
            "ENV_GAMENIGHT": crate::ENV_GAMENIGHT,
            "ENV_ADDR": crate::ENV_ADDR,
            "ENV_GAME_ID": crate::ENV_GAME_ID,
            "ENV_TOKEN": crate::ENV_TOKEN,
            "ENV_OVERLAY_URL": crate::ENV_OVERLAY_URL,
        },
        "avatar": {
            "AVATAR_FORMAT_VERSION": avatar::FORMAT_VERSION,
            "AVATAR_SIZE": avatar::SIZE,
            "AVATAR_MAX_SIDE": avatar::MAX_SIDE,
            "AVATAR_LEGACY_TRANSPARENT": avatar::LEGACY_TRANSPARENT,
            "AVATAR_HEAD_X": avatar::HEAD_X,
            "AVATAR_HEAD_Y": avatar::HEAD_Y,
            "AVATAR_HEAD_RADIUS": avatar::HEAD_RADIUS,
            "GUEST_COLORS": guest_face::COLORS,
            "GUEST_SKINS": guest_face::SKINS,
        },
        "artwork": {
            "ARTWORK_MAX_PNG_BYTES": artwork::MAX_PNG_BYTES,
            "ARTWORK_MAX_DIMENSION": artwork::MAX_DIMENSION,
            "ARTWORK_PNG_PREFIX": artwork::PNG_PREFIX,
        },
    })
}

/// The schema as committed: pretty JSON with a trailing newline.
pub fn protocol_schema_pretty() -> String {
    serde_json::to_string_pretty(&protocol_schema()).unwrap() + "\n"
}

/// `contract/protocol.schema.json` in this checkout.
pub fn workspace_schema_path() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../contract/protocol.schema.json")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn schema_json_is_up_to_date() {
        let fresh = protocol_schema_pretty();
        let path = workspace_schema_path();
        if std::env::var_os("GAMENIGHT_WRITE_SCHEMA").is_some() {
            std::fs::write(&path, &fresh).unwrap();
            return;
        }
        let committed = std::fs::read_to_string(&path).unwrap_or_default();
        assert!(
            committed == fresh,
            "contract/protocol.schema.json is stale. Run \
             `GAMENIGHT_WRITE_SCHEMA=1 cargo test -p gamenight-protocol schema` \
             and then `python3 scripts/build-protocol.py`."
        );
    }

    #[test]
    fn every_message_type_is_listed() {
        let schema = protocol_schema();
        let defs = &schema["$defs"];
        for side in ["ClientMessage", "ServerMessage"] {
            let variants = defs[side]["oneOf"].as_array().expect(side);
            assert!(variants.len() > 5, "{side} has variants");
            for variant in variants {
                assert!(
                    variant["properties"]["type"]["const"].is_string(),
                    "{side} variant without a type tag: {variant}"
                );
            }
        }
    }
}
