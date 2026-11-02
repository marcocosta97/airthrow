#!/usr/bin/env python3
"""Check website routing without checkout or bundled-resource dependencies."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
binary = ROOT / '.build/debug/SourceRegistryChecks'
subprocess.run(['swift', 'build', '--configuration', 'debug', '--product', 'SourceRegistryChecks',
                '--disable-sandbox'], cwd=ROOT, check=True, timeout=240)

with tempfile.TemporaryDirectory(prefix='athrow-registry-') as temporary:
    root = Path(temporary)
    standalone = root / 'RegistryCheck'
    shutil.copy2(binary, standalone)
    subprocess.run([str(standalone), '--routing-only'], cwd='/', check=True, timeout=60)

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
