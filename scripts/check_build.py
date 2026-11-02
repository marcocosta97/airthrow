"""Build check harnesses against SwiftPM's shared Debug Core objects."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PLAYER_SOURCES = (
    "MediaDiagnostics.swift", "InterfaceCopy.swift", "PlaybackController.swift",
    "NetworkLibraryModel.swift", "XtreamLibrary.swift", "ReceiverWaitingScreen.swift",
)


def build_check(name, output, app_sources=()):
    # SwiftPM owns source/toolchain invalidation; each runner keeps its own build.
    subprocess.run(["swift", "build", "--configuration", "debug", "--target", "AirThrowCore",
                    "--disable-sandbox"], cwd=ROOT, check=True, timeout=240)
    binary_dir = Path(subprocess.check_output(
        ["swift", "build", "--configuration", "debug", "--show-bin-path"], cwd=ROOT, text=True).strip())
    # Xcode's Swift build engine emits one merged object; classic SwiftPM emits one per file.
    objects = [binary_dir / "AirThrowCore.o"] if (binary_dir / "AirThrowCore.o").is_file() else sorted(
        (binary_dir / "AirThrowCore.build").glob("*.o"))
    if not objects:
        raise RuntimeError("SwiftPM did not produce AirThrowCore objects")
    modules = binary_dir / "Modules" if (binary_dir / "Modules").is_dir() else binary_dir
    output = Path(output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([
        "swiftc", "-swift-version", "6", "-parse-as-library", "-D", "SWIFT_PACKAGE",
        "-I", str(ROOT / "Sources/CSQLite"), "-I", str(modules),
        *map(str, objects),
        *(str(ROOT / "Sources/AirThrowApp" / source) for source in app_sources),
        str(ROOT / "Tests" / name / "main.swift"), "-o", str(output),
    ], cwd=ROOT, check=True, timeout=180)
    return output


if __name__ == "__main__":
    name = sys.argv[1]
    app_sources = PLAYER_SOURCES + ("SettingsView.swift",) if name == "SettingsChecks" else ()
    build_check(name, ROOT / "build/checks" / name, app_sources)
