#!/usr/bin/env python3
"""Upload a signed Play bundle to internal testing. Never targets production."""
import json
import os
from pathlib import Path
import sys

from google.oauth2 import service_account
from googleapiclient.discovery import build
from googleapiclient.http import MediaFileUpload


def publish(bundle, version):
    credentials = service_account.Credentials.from_service_account_info(
        json.loads(os.environ["GOOGLE_PLAY_SERVICE_ACCOUNT_JSON"]),
        scopes=["https://www.googleapis.com/auth/androidpublisher"],
    )
    service = build("androidpublisher", "v3", credentials=credentials,
                    cache_discovery=False)
    edits = service.edits()
    package = "io.ontola.gamenight"
    edit = edits.insert(packageName=package, body={}).execute()["id"]
    args = {"packageName": package, "editId": edit}
    try:
        uploaded = edits.bundles().upload(
            **args,
            media_body=MediaFileUpload(str(bundle), mimetype="application/octet-stream",
                                      resumable=True),
        ).execute()
        if int(uploaded["versionCode"]) != version:
            raise ValueError("Uploaded bundle version does not match this workflow run")
        edits.tracks().update(**args, track="internal", body={
            "track": "internal",
            "releases": [{"name": f"GameNight {version}",
                          "versionCodes": [str(version)], "status": "completed"}],
        }).execute()
        edits.commit(**args).execute()
    except BaseException:
        # Drop only our uncommitted edit; never replace an existing release on failure.
        try:
            edits.delete(**args).execute()
        except Exception:
            pass
        raise
    print(f"GameNight build {version} published to Google Play internal testing.")


if __name__ == "__main__":
    publish(Path(sys.argv[1]), int(sys.argv[2]))
