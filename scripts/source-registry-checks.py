#!/usr/bin/env python3
"""Check manifest discovery in relocated standalone and macOS app layouts."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / 'build/source-registry-checks'
BUILD.mkdir(parents=True, exist_ok=True)
binary = BUILD / 'SourceRegistryChecks'
subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library',
                '-module-cache-path', str(BUILD / 'ModuleCache'),
                *map(str, sorted((ROOT / 'Sources/AirThrowCore').glob('*.swift'))),
                str(ROOT / 'Tests/SourceRegistryChecks/main.swift'), '-o', str(binary)],
               cwd=ROOT, check=True, timeout=180)

with tempfile.TemporaryDirectory(prefix='athrow-registry-') as temporary:
    root = Path(temporary)
    standalone = root / 'RegistryCheck'
    shutil.copy2(binary, standalone)
    shutil.copytree(ROOT / 'Sources/AirThrowCore/SourceProviders', root / 'SourceProviders')
    subprocess.run([str(standalone)], cwd='/', check=True, timeout=60)

    contents = root / 'Registry.app/Contents'
    (contents / 'MacOS').mkdir(parents=True)
    (contents / 'Resources').mkdir()
    app_check = contents / 'MacOS/RegistryCheck'
    shutil.copy2(binary, app_check)
    providers = contents / 'Resources/SourceProviders'
    shutil.copytree(ROOT / 'Sources/AirThrowCore/SourceProviders', providers)
    (contents / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleExecutable': 'RegistryCheck', 'CFBundleIdentifier': 'app.airthrow.registry-check',
        'CFBundlePackageType': 'APPL'}))
    subprocess.run([str(app_check), '--bundled-only'], cwd='/', check=True, timeout=30)

    # Add a provider solely through its JSON file, without rebuilding or wiring
    # the test binary. This fixture is not a claim of support for a public site.
    manifest = providers / 'community.json'
    definition = dict(schemaVersion=1, id='community-video', name='Community fixture',
                      hosts=['community.example'], extractors=['example:video'])
    manifest.write_text(json.dumps(definition))
    payload = root / 'metadata.json'
    payload.write_text(json.dumps(dict(_type='video', formats=[dict(
        format_id='combined', url='https://cdn.example/fixture.mp4', protocol='https',
        vcodec='avc1.640028', acodec='mp4a.40.2', ext='mp4', height=1080)])))
    helper = root / 'yt-dlp-fixture'
    helper.write_text(f'#!/bin/sh\ncat "{payload}"\n')
    helper.chmod(0o700)
    environment = dict(os.environ, AIRTHROW_YTDLP=str(helper), AIRTHROW_DENO='/missing/deno')
    subprocess.run([str(app_check), '--resolve-manifest', 'https://community.example/watch',
                    'community-video'], cwd='/', env=environment, check=True, timeout=30)

    definition['hosts'] = ['youtu.be']
    manifest.write_text(json.dumps(definition))
    rejected = subprocess.run([str(app_check), '--bundled-only'], cwd='/',
                              capture_output=True, text=True, timeout=30)
    assert rejected.returncode == 1 and 'duplicateHost' in rejected.stderr, \
        'Conflicting bundled source was silently accepted'
    print('PASS relocated resources, automatic added-provider discovery and conflict rejection')

print('Source registry integration passed; no public site or receiver playback tested.')
