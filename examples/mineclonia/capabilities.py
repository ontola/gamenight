"""The same live-setting contract is consumed by Python and the world mod."""
import json
import math
from pathlib import Path
SPECS = json.loads((Path(__file__).parent / 'mods/gamenight_bridge/settings.json').read_text(encoding='utf-8'))

def valid(key, value):
    s = SPECS.get(key)
    return bool(s and type(value) in (int, float) and math.isfinite(value) and s['min'] <= value <= s['max'])

def controls(values):
    return {key: {field: s[field] for field in ('label', 'min', 'max', 'description', 'unit', 'applies')} | {'value': values[key]}
            for key, s in SPECS.items() if key in values}
