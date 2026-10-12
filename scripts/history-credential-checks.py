#!/usr/bin/env python3
"""History privacy/lifecycle checks; optional real Keychain test never presents UI."""
from pathlib import Path
import argparse
import os
import subprocess

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument('--keychain', action='store_true', help='Also check the local Keychain with synthetic data and no UI')
args = parser.parse_args()
build = root / 'build' / 'history-credential-checks'
build.mkdir(parents=True, exist_ok=True)
binary = build / 'HistoryCredentialChecks'
env = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(build / 'ModuleCache'), SWIFT_MODULECACHE_PATH=str(build / 'ModuleCache'))
subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library', '-module-cache-path', str(build / 'ModuleCache'),
                *map(str, sorted((root / 'Sources/AirThrowCore').glob('*.swift'))),
                str(root / 'Tests/MediaHistoryCredentialChecks/main.swift'), '-o', str(binary)], cwd=root, env=env, check=True, timeout=180)
subprocess.run([str(binary), *(['--keychain'] if args.keychain else [])], cwd=root, env=env, check=True, timeout=30)
