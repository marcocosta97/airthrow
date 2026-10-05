#!/usr/bin/env python3
"""Check waiting-screen lifecycle with real media and a simulated external route."""
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parent.parent
binary = root / 'build' / 'WaitingScreenChecks'
binary.parent.mkdir(exist_ok=True)
subprocess.run(['swiftc', '-swift-version', '6', '-parse-as-library',
                *sorted((root / 'Sources/AirThrowCore').glob('*.swift')),
                root / 'Sources/AirThrowApp/MediaDiagnostics.swift',
                root / 'Sources/AirThrowApp/ReceiverWaitingScreen.swift',
                root / 'Sources/AirThrowApp/PlaybackController.swift',
                root / 'Tests/WaitingScreenChecks/main.swift', '-o', binary], check=True)
subprocess.run([binary, root / 'Resources/WaitingScreen'], cwd=root, check=True, timeout=240)
