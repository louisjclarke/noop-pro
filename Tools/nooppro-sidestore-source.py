#!/usr/bin/env python3
"""Write the NOOP Pro SideStore / AltStore source (AltStore 2 format) for the build just packaged.

Usage:
  nooppro-sidestore-source.py APP_DIR IPA_PATH IPA_URL ICON_URL SOURCE_URL NOTES OUT_JSON

Everything that must match the installed app (bundle id, version, build number, privacy strings,
entitlements) is read from the built .app itself, so the source can never describe a different build.
"""
import datetime
import hashlib
import os
import plistlib
import subprocess
import sys


def entitlements(path):
    try:
        out = subprocess.run(["codesign", "-d", "--entitlements", ":-", path],
                             capture_output=True, check=True).stdout
        return plistlib.loads(out) if out.strip() else {}
    except Exception:
        return {}


def main():
    app, ipa, ipa_url, icon_url, source_url, notes, out = sys.argv[1:8]
    with open(os.path.join(app, "Info.plist"), "rb") as f:
        info = plistlib.load(f)

    ents = set(entitlements(app))
    plugins = os.path.join(app, "PlugIns")
    if os.path.isdir(plugins):
        for name in sorted(os.listdir(plugins)):
            ents |= set(entitlements(os.path.join(plugins, name)))
    privacy = {k: v for k, v in info.items() if k.startswith("NS") and k.endswith("UsageDescription")}

    with open(ipa, "rb") as f:
        data = f.read()
    version = info["CFBundleShortVersionString"]
    build = info["CFBundleVersion"]
    today = datetime.date.today().isoformat()
    description = ("NOOP Pro: an offline WHOOP companion with live Dexcom G7 glucose, Body Age, Whole Picture "
                   "and everything NOOP computes on your phone.")
    entry = {
        "version": version,
        "buildVersion": build,
        "date": today,
        "localizedDescription": notes,
        "downloadURL": ipa_url,
        "size": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "minOSVersion": info.get("MinimumOSVersion", "17.0"),
    }
    source = {
        "name": "NOOP Pro",
        "identifier": "com.louisjclarke.nooppro.source",
        "sourceURL": source_url,
        "subtitle": "Louis's NOOP Pro builds",
        "description": description,
        "iconURL": icon_url,
        "tintColor": "#03E095",
        "apps": [{
            "name": "NOOP Pro",
            "bundleIdentifier": info["CFBundleIdentifier"],
            "developerName": "Louis Clarke",
            "subtitle": "WHOOP + Dexcom, on your phone",
            "localizedDescription": description,
            "iconURL": icon_url,
            "tintColor": "#03E095",
            "category": "lifestyle",
            "screenshotURLs": [],
            "versions": [entry],
            # Legacy (AltStore 1.x) fields, mirroring the newest version.
            "version": version,
            "buildVersion": build,
            "versionDate": today,
            "versionDescription": notes,
            "downloadURL": ipa_url,
            "size": len(data),
            "appPermissions": {
                "entitlements": sorted(ents),
                "privacy": privacy,
            },
        }],
        "news": [],
    }
    import json
    with open(out, "w") as f:
        json.dump(source, f, indent=2, ensure_ascii=False)
    print(f"source: {info['CFBundleIdentifier']} {version} ({build}), {len(data)} bytes, "
          f"{len(ents)} entitlements, {len(privacy)} privacy keys")


if __name__ == "__main__":
    main()
