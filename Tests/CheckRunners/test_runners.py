import ast
import importlib.util
import io
import runpy
import sys
from types import SimpleNamespace
from contextlib import redirect_stdout
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

SPEC = importlib.util.spec_from_file_location(
    "check_build", Path(__file__).resolve().parents[2] / "scripts/check_build.py")
builder = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(builder)


class CheckBuildTests(unittest.TestCase):
    def test_links_both_swiftpm_layouts_and_rejects_missing_objects(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for layout in ("xcode", "classic", "missing"):
                with self.subTest(layout=layout):
                    binary_dir = root / layout
                    binary_dir.mkdir()
                    if layout == "xcode":
                        objects = [binary_dir / "AirThrowCore.o"]
                        modules = binary_dir
                    else:
                        object_dir = binary_dir / "AirThrowCore.build"
                        object_dir.mkdir()
                        objects = [object_dir / "One.swift.o", object_dir / "Two.swift.o"]
                        modules = binary_dir / "Modules"
                        modules.mkdir()
                    if layout != "missing":
                        for obj in objects:
                            obj.touch()
                    with patch.object(builder.subprocess, "run") as run, patch.object(
                            builder.subprocess, "check_output", return_value=str(binary_dir)):
                        if layout == "missing":
                            with self.assertRaisesRegex(RuntimeError, "Core objects"):
                                builder.build_check("ResolverChecks", root / "Checks")
                            self.assertEqual(run.call_count, 1)
                        else:
                            builder.build_check("ResolverChecks", root / "Checks")
                            command = run.call_args.args[0]
                            self.assertTrue(all(str(obj) in command for obj in objects))
                            self.assertIn(str(modules), command)
                            self.assertFalse(any("Sources/AirThrowCore/" in arg for arg in command))

    def test_compile_only_never_generates_media(self):
        for flags, name in [([], 'SourceChoiceChecks'), (['--controller'], 'ControllerChecks'),
                            (['--system-playback'], 'SystemPlaybackChecks')]:
            build = Mock()
            stub = SimpleNamespace(build_check=build, PLAYER_SOURCES=builder.PLAYER_SOURCES)
            script = str(builder.ROOT / 'scripts/source-choice-checks.py')
            with self.subTest(suite=name), patch.dict(sys.modules, check_build=stub), patch.object(
                    sys, 'argv', [script, '--compile-only', *flags]), patch(
                    'tempfile.mkdtemp', side_effect=AssertionError('Created fixtures')), patch(
                    'subprocess.run', side_effect=AssertionError('Ran a media command')), redirect_stdout(io.StringIO()):
                with self.assertRaises(SystemExit) as result:
                    runpy.run_path(script, run_name='__main__')
                self.assertEqual(result.exception.code, 0)
                self.assertEqual(build.call_args.args[0], name)

    def test_native_correctness_cases_require_an_expected_outcome(self):
        script = builder.ROOT / 'scripts/native-media-checks.py'
        function = next(node for node in ast.parse(script.read_text()).body
                        if isinstance(node, ast.FunctionDef) and node.name == 'case')
        scope = {'cases': [], 'args': SimpleNamespace(diagnostic=False)}
        exec(compile(ast.Module(body=[function], type_ignores=[]), str(script), 'exec'), scope)
        with self.assertRaisesRegex(ValueError, 'expected state'):
            scope['case']('MOV', 'video.mov', 'MOV', 'H.264', 'AAC')
        scope['case']('MOV', 'video.mov', 'MOV', 'H.264', 'AAC', expected='awaiting_receiver')
        self.assertEqual(scope['cases'][0]['expectedState'], 'awaiting_receiver')
        scope['args'].diagnostic = True
        scope['case']('Probe', 'video.mkv', 'MKV', 'H.264', 'AAC')
        self.assertIsNone(scope['cases'][-1]['expectedState'])

    def test_progressive_only_generates_its_own_media(self):
        script = builder.ROOT / 'scripts/preparation-checks.py'
        nodes = ast.parse(script.read_text()).body
        declarations = [node for node in nodes if (
            isinstance(node, ast.FunctionDef) and node.name == 'ffmpeg') or (
            isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == 'PROGRESSIVE_FIXTURES'
                                               for t in node.targets))]
        run = Mock()
        scope = {'PROGRESSIVE_ONLY': True, 'Path': Path, 'run': run, 'FFMPEG': 'ffmpeg'}
        exec(compile(ast.Module(body=declarations, type_ignores=[]), str(script), 'exec'), scope)
        scope['ffmpeg']('unused-hdr.mkv')
        run.assert_not_called()
        scope['ffmpeg']('combined.mp4')
        self.assertEqual(run.call_args.args[0][-1], 'combined.mp4')
        scope['PROGRESSIVE_ONLY'] = False
        scope['ffmpeg']('unused-hdr.mkv')
        self.assertEqual(run.call_count, 2)


if __name__ == "__main__":
    unittest.main()
