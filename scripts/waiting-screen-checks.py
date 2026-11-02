#!/usr/bin/env python3
"""Check waiting-screen lifecycle with real media and a simulated external route."""
from check_build import build_check, PLAYER_SOURCES
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
binary = root / 'build' / 'WaitingScreenChecks'
binary.parent.mkdir(exist_ok=True)
build_check('WaitingScreenChecks', binary, PLAYER_SOURCES)
subprocess.run([binary, root / 'Resources/WaitingScreen'], cwd=root, check=True, timeout=240)
