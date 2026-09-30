#!/usr/bin/env python3
"""Check website routing without checkout or bundled-resource dependencies."""
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
    subprocess.run([str(standalone)], cwd='/', check=True, timeout=60)

    contents = root / 'Registry.app/Contents'
    (contents / 'MacOS').mkdir(parents=True)
    (contents / 'Resources').mkdir()
    app_check = contents / 'MacOS/RegistryCheck'
    shutil.copy2(binary, app_check)
    (contents / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleExecutable': 'RegistryCheck', 'CFBundleIdentifier': 'app.airthrow.registry-check',
        'CFBundlePackageType': 'APPL'}))
    subprocess.run([str(app_check), '--routing-only'], cwd='/', check=True, timeout=30)
    print('PASS relocated standalone and app routing with no source configuration files')

print('Source registry integration passed; no public site or receiver playback tested.')
