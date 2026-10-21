#!/usr/bin/env python3
"""Restore provider config without echoing it; absent secrets leave push off."""
import base64
import json
import os
from pathlib import Path
import plistlib
import sys

root = Path(__file__).resolve().parents[1]
platform = sys.argv[1]
if platform == 'android':
    value = os.environ.get('GOOGLE_SERVICES_JSON', '')
    path = root / 'android/app/google-services.json'
    if value:
        raw = base64.b64decode(value, validate=True)
        config = json.loads(raw)
        assert any(c['client_info']['android_client_info']['package_name'] == 'io.ontola.gamenight'
                   for c in config['client']), 'Wrong Android Firebase app'
        path.write_bytes(raw)
elif platform == 'ios':
    value = os.environ.get('GOOGLE_SERVICE_INFO_PLIST', '')
    path = root / 'ios/Runner/GoogleService-Info.plist'
    if value:
        raw = base64.b64decode(value, validate=True)
        assert plistlib.loads(raw)['BUNDLE_ID'] == 'io.ontola.gamenight', 'Wrong iOS Firebase app'
        path.write_bytes(raw)
    xcconfig = root / 'ios/Flutter/Firebase.xcconfig'
    if value:
        xcconfig.write_text('GAMENIGHT_PUSH_ENTITLEMENTS = Runner/Runner.entitlements\n'
                            'GAMENIGHT_APS_ENVIRONMENT = production\n'
                            'GAMENIGHT_APS_ENVIRONMENT[config=Debug] = development\n')
    else:
        xcconfig.unlink(missing_ok=True)
else:
    raise SystemExit('Expected android or ios')
if not value:
    path.unlink(missing_ok=True)
if os.environ.get('GITHUB_ENV'):
    with open(os.environ['GITHUB_ENV'], 'a') as env:
        env.write(f'GAMENIGHT_PUSH={str(bool(value)).lower()}\n')
print(f'Push configuration: {platform}, {"enabled" if value else "disabled"}')
