import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "macOS packaging tools required")
class ReleasePackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        scripts = self.root / "scripts"
        scripts.mkdir()
        shutil.copy(ROOT / "scripts/package-release.sh", scripts)
        (scripts / "build.sh").write_text('''#!/bin/bash
set -euo pipefail
python3 - <<'PY'
import os, pathlib, plistlib
root = pathlib.Path(os.environ["AIRTHROW_BUILD_DIR"])
app = root / "AirThrow.app"
share = app / "Contents/PlugIns/AirThrowShare.appex"
for bundle, binaries in [(app, ["AirThrowApp", "athrow"]), (share, ["AirThrowShare"])]:
    (bundle / "Contents/MacOS").mkdir(parents=True)
    for name in binaries:
        binary = bundle / "Contents/MacOS" / name
        binary.write_text("#!/bin/sh\\nexit 0\\n")
        binary.chmod(0o700)
    with (bundle / "Contents/Info.plist").open("wb") as output:
        plistlib.dump({"CFBundleShortVersionString": os.environ["AIRTHROW_VERSION"],
                      "CFBundleVersion": os.environ["AIRTHROW_BUILD_NUMBER"]}, output)
PY
ditto -c -k --keepParent "$AIRTHROW_BUILD_DIR/AirThrow.app" "$AIRTHROW_BUILD_DIR/AirThrow.zip"
''')
        tools = self.root / "tools"
        tools.mkdir()
        stub = tools / "tool"
        stub.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["TOOL_LOG"], "a") as log:
    log.write(json.dumps([name, *args]) + "\\n")
if name in ("uname", "lipo"):
    print("arm64")
elif name == "xcrun" and args[:2] == ["notarytool", "submit"]:
    print(json.dumps({"id": "fixture-submission", "status": os.environ.get("NOTARY_STATUS", "Accepted")}))
    sys.exit(int(os.environ.get("NOTARY_EXIT", "0")))
elif name == "xcrun" and args[:2] == ["notarytool", "log"]:
    pathlib.Path(args[-1]).write_text('{"issues": null}')
elif name == "xcrun" and args[0] == "stapler":
    ticket = pathlib.Path(args[-1]) / "Contents/notarization-ticket"
    if args[1] == "staple":
        ticket.write_text("fixture-ticket")
    else:
        assert ticket.is_file(), "Final ZIP omitted the stapled ticket"
        sys.exit(int(os.environ.get("STAPLER_EXIT", "0")))
elif name == "spctl":
    sys.exit(int(os.environ.get("GATEKEEPER_EXIT", "0")))
''')
        stub.chmod(0o700)
        for name in ("uname", "lipo", "codesign", "xcrun", "spctl"):
            (tools / name).symlink_to(stub)
        self.build = self.root / "build"
        self.log = self.root / "tool-log.jsonl"
        self.env = {
            **os.environ,
            "PATH": f"{tools}:{os.environ['PATH']}",
            "AIRTHROW_BUILD_DIR": str(self.build),
            "CODE_SIGN_IDENTITY": "Developer ID Application: Fixture (FIXTURE)",
            "NOTARY_KEYCHAIN_PROFILE": "fixture-profile",
            "AIRTHROW_SIGNING_KEYCHAIN": "/fixture/keychain with spaces",
            "GITHUB_RUN_NUMBER": "17",
            "TOOL_LOG": str(self.log),
        }

    def run_package(self, **overrides):
        shutil.rmtree(self.build, ignore_errors=True)
        self.log.unlink(missing_ok=True)
        return subprocess.run(
            ["bash", str(self.root / "scripts/package-release.sh"), "v1.2.3"],
            env={**self.env, **overrides}, text=True, capture_output=True)

    def test_requires_distribution_identity_and_notarization_profile_before_build(self):
        for overrides in ({"CODE_SIGN_IDENTITY": ""}, {"CODE_SIGN_IDENTITY": "-"},
                          {"CODE_SIGN_IDENTITY": "Apple Development: Fixture"},
                          {"NOTARY_KEYCHAIN_PROFILE": ""}):
            with self.subTest(overrides=overrides):
                result = self.run_package(**overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.build.exists())
                self.assertFalse(self.log.exists())

    def test_ships_stapled_app_and_checks_extracted_archive(self):
        result = self.run_package()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        archive = self.build / "release/AirThrow-1.2.3-arm64.zip"
        with zipfile.ZipFile(archive) as final:
            self.assertIn("AirThrow.app/Contents/notarization-ticket", final.namelist())
            metadata = plistlib.loads(final.read("AirThrow.app/Contents/Info.plist"))
            self.assertEqual(metadata["CFBundleVersion"], "17")
        commands = [json.loads(line) for line in self.log.read_text().splitlines()]
        submit = next(command for command in commands if command[1:3] == ["notarytool", "submit"])
        self.assertEqual(submit[submit.index("--keychain") + 1], "/fixture/keychain with spaces")
        self.assertTrue((self.build / "notarization-log.json").is_file())
        assessed = next(command[-1] for command in commands if command[0] == "spctl")
        self.assertNotEqual(assessed, str(self.build / "AirThrow.app"))

    def test_never_packages_unaccepted_or_failed_submissions(self):
        for overrides in ({"NOTARY_STATUS": "Invalid"}, {"NOTARY_STATUS": "In Progress"},
                          {"NOTARY_STATUS": "Invalid", "NOTARY_EXIT": "65"},
                          {"NOTARY_EXIT": "1"}):
            with self.subTest(overrides=overrides):
                result = self.run_package(**overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.build / "release").exists())
                self.assertTrue((self.build / "notarization-log.json").is_file())

    def test_rejects_failed_ticket_or_gatekeeper_validation(self):
        for overrides in ({"STAPLER_EXIT": "65"}, {"GATEKEEPER_EXIT": "3"}):
            with self.subTest(overrides=overrides):
                result = self.run_package(**overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("Packaged ", result.stdout)


if __name__ == "__main__":
    unittest.main()
