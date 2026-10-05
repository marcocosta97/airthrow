#!/usr/bin/env python3
"""Generate the AirThrow Homebrew cask for a released version.

Usage:
    generate-cask.py VERSION SHA256

VERSION is the release version without the leading "v" (for example "0.1.0").
SHA256 is the lowercase 64-character hex digest of the arm64 zip asset. The
generated cask is written to stdout.
"""

import re
import sys

VERSION_PATTERN = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")

CASK_TEMPLATE = """cask "airthrow" do
  version "%(version)s"
  sha256 "%(sha256)s"

  url "https://github.com/marcocosta97/airthrow/releases/download/v#{version}/AirThrow-#{version}-arm64.zip"
  name "AirThrow"
  desc "Send video links and local files to Apple TV and other AirPlay receivers"
  homepage "https://github.com/marcocosta97/airthrow"

  depends_on arch: :arm64
  depends_on macos: :sonoma
  depends_on formula: ["deno", "ffmpeg", "yt-dlp"]

  app "AirThrow.app"
  binary "#{appdir}/AirThrow.app/Contents/MacOS/athrow"

  caveats <<~EOS
    AirThrow is ad-hoc signed and not notarized. On first launch macOS may
    block it: open System Settings > Privacy & Security and choose
    "Open Anyway" for AirThrow.app. The bundled athrow command line tool may
    require separate approval.
  EOS
end
"""


def fail(message):
    print(message, file=sys.stderr)
    return 2


def main(argv):
    if len(argv) != 3:
        return fail("usage: generate-cask.py VERSION SHA256")

    version, sha256 = argv[1], argv[2]
    if not VERSION_PATTERN.fullmatch(version):
        return fail("invalid version: expected X.Y.Z, got %r" % version)
    if not SHA256_PATTERN.fullmatch(sha256):
        return fail("invalid sha256: expected 64 lowercase hex characters")

    sys.stdout.write(CASK_TEMPLATE % {"version": version, "sha256": sha256})
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
