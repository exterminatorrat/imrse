import hashlib
import importlib.util
import json
import signal
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = ROOT / "scripts/test-mlx-getters.py"
FIXTURE_PATH = ROOT / "scripts/tests/fixtures/MLXGetterCompatibility.swift"
SPEC = importlib.util.spec_from_file_location("test_mlx_getters", SCRIPT_PATH)
harness = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(harness)

SOURCE = """@propertyWrapper public class ParameterInfo<T> {
    var value: T?

    public var wrappedValue: T {
        get {
            if let value = (value as Any) as? T {
                return value
            } else {
                return value!
            }
        }
    }
}

@propertyWrapper public class ModuleInfo<T>: TypeErasedSetterProvider {
    var module: T?

    public var wrappedValue: T {
        get {
            if let module = (module as Any) as? T {
                return module
            } else {
                return module!
            }
        }
    }
}
"""
SOURCE_BYTES = SOURCE.encode("utf-8")
SOURCE_SHA256 = hashlib.sha256(SOURCE_BYTES).hexdigest()


def approved_patch():
    replacements = []
    for name in ("value", "module"):
        replacements.append({
            "oldText": f"if let {name} = {name} as? T {{\n                return {name}",
            "newText": f"if let {name} = ({name} as Any) as? T {{\n                return {name}",
        })
    return {
        "schemaVersion": 1,
        "identity": "mlx-swift",
        "version": "0.31.6",
        "revision": "0bb916c67f4b9e5c682cbe02a42c701c93ab5021",
        "files": [
            {"path": "Source/MLX/MLXArray+maskFill.swift"},
            {
                "path": harness.MODULE_PATH,
                "originalSHA256": harness.EXPECTED_ORIGINAL_SHA256,
                "originalSize": harness.EXPECTED_ORIGINAL_SIZE,
                "patchedSHA256": SOURCE_SHA256,
                "patchedSize": len(SOURCE_BYTES),
                "replacements": replacements,
            },
        ],
    }


class MLXGetterFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        module_path = self.root / harness.MODULE_CHECKOUT / harness.MODULE_PATH
        module_path.parent.mkdir(parents=True)
        module_path.write_bytes(SOURCE_BYTES)
        scripts = self.root / "scripts"
        scripts.mkdir()
        fixture = scripts / "tests/fixtures/MLXGetterCompatibility.swift"
        fixture.parent.mkdir(parents=True)
        shutil.copyfile(FIXTURE_PATH, fixture)
        approval = approved_patch()
        helper = scripts / "patch-mlx-mask-fill.py"
        helper.write_text(f"APPROVED_MLX_PATCH = {approval!r}\nraise AssertionError('executed approval source')\n",
                          encoding="utf-8")
        self.output = self.root / "OUT"
        self.work = self.root / "WORK"
        self.args = SimpleNamespace(source_root=self.root, output_dir=self.output, work_dir=self.work)
        self.patch_constants = patch.multiple(
            harness,
            EXPECTED_PATCHED_SIZE=len(SOURCE_BYTES),
            EXPECTED_PATCHED_SHA256=SOURCE_SHA256,
        )
        self.patch_constants.start()
        self.addCleanup(self.patch_constants.stop)
        self.host_patches = [
            patch.object(harness.platform, "system", return_value="Darwin"),
            patch.object(harness.platform, "machine", return_value="arm64"),
            patch.dict(harness.os.environ, {
                "GITHUB_ACTIONS": "true",
                "RUNNER_ENVIRONMENT": "github-hosted",
                "RUNNER_OS": "macOS",
                "RUNNER_ARCH": "ARM64",
            }, clear=True),
        ]
        for item in self.host_patches:
            item.start()
            self.addCleanup(item.stop)

    def invoke(self, side_effect=None):
        calls = []

        def successful_process(argv, **kwargs):
            calls.append(argv)
            if argv[0] == "swiftc":
                return SimpleNamespace(returncode=0, stdout="compiler output\n", stderr="compiler diagnostic\n")
            if len(argv) == 1:
                return SimpleNamespace(returncode=0, stdout=harness.MATRIX_SENTINEL + "\n", stderr="matrix detail\n")
            marker = f"GETTER_TRAP_MODE:{argv[1][2:]}"
            return SimpleNamespace(returncode=-signal.SIGILL, stdout="", stderr=marker + "\nFatal error: expected trap")

        process = side_effect or successful_process
        with patch.object(harness.subprocess, "run", side_effect=process):
            path = harness.run(self.args)
        return path, calls

    def test_success_compiles_exact_extracted_getters_and_records_provenance(self):
        log_path, calls = self.invoke()
        log = log_path.read_text(encoding="utf-8")
        lines = log.splitlines()
        self.assertEqual(lines[-1], harness.SUCCESS_MARKER)
        self.assertIn(f"source_sha256={SOURCE_SHA256}", lines)
        generated = (self.work / harness.GENERATED_NAME).read_text(encoding="utf-8")
        template = FIXTURE_PATH.read_text(encoding="utf-8")
        expected = template.replace("__PARAMETER_GETTER__", harness._extract_getter(SOURCE, "ParameterInfo"))
        expected = expected.replace("__MODULE_GETTER__", harness._extract_getter(SOURCE, "ModuleInfo"))
        self.assertEqual(generated, expected)
        self.assertIn(f"generated_source_sha256={hashlib.sha256(generated.encode()).hexdigest()}", lines)
        self.assertIn('compile_returncode=0', lines)
        self.assertIn('compile_stdout="compiler output\\n"', lines)
        self.assertIn('compile_stderr="compiler diagnostic\\n"', lines)
        self.assertIn("matrix_returncode=0", lines)
        self.assertIn('matrix_stdout="GETTER_MATRIX_PASSED\\n"', lines)
        self.assertIn('matrix_stderr="matrix detail\\n"', lines)
        for label in ("parameter_missing_value", "module_missing_value",
                      "parameter_negative_control", "module_negative_control"):
            self.assertIn(f"{label}_returncode={-signal.SIGILL}", lines)
        self.assertIn('parameter_missing_value_stderr="GETTER_TRAP_MODE:missing-parameter\\nFatal error: expected trap"', lines)
        compile_argv = json.loads(next(line.removeprefix("compile_argv=") for line in lines
                                       if line.startswith("compile_argv=")))
        self.assertEqual(compile_argv[:6], ["swiftc", "-parse-as-library", "-swift-version", "6",
                                             "-warnings-as-errors", "-O"])
        self.assertEqual(compile_argv[-2:], ["-o", str((self.work / harness.BINARY_NAME).resolve())])
        self.assertEqual(calls[0], compile_argv)
        self.assertEqual([call[1] for call in calls[2:]], [
            "--missing-parameter", "--missing-module",
            "--negative-control-parameter", "--negative-control-module",
        ])
        self.assertIn("-warnings-as-errors", compile_argv)
        self.assertFalse(any("suppress" in arg for arg in compile_argv))
        self.assertIn("not an MLX/Metal module acceptance test", log)

    def test_tampered_source_invalidates_stale_success_log_without_running_compiler(self):
        self.output.mkdir()
        log_path = self.output / harness.LOG_NAME
        log_path.write_text(harness.SUCCESS_MARKER + "\n", encoding="utf-8")
        module_path = self.root / harness.MODULE_CHECKOUT / harness.MODULE_PATH
        module_path.write_bytes(SOURCE_BYTES + b"tamper")
        with patch.object(harness.subprocess, "run") as process:
            with self.assertRaisesRegex(harness.HarnessError, "size or SHA-256"):
                harness.run(self.args)
        process.assert_not_called()
        self.assertNotIn(harness.SUCCESS_MARKER, log_path.read_text(encoding="utf-8"))

    def test_compile_failure_records_no_success_marker(self):
        def failed_compile(argv, **kwargs):
            return SimpleNamespace(returncode=1, stdout="compiler stdout", stderr="compile failure")

        with self.assertRaisesRegex(harness.HarnessError, "compilation failed"):
            self.invoke(side_effect=failed_compile)
        log = (self.output / harness.LOG_NAME).read_text(encoding="utf-8")
        self.assertNotIn(harness.SUCCESS_MARKER, log)
        self.assertIn("compile_argv=", log)
        self.assertIn("compile_returncode=1", log)
        self.assertIn('compile_stdout="compiler stdout"', log)
        self.assertIn('compile_stderr="compile failure"', log)

    def test_matrix_failure_records_child_output_before_failure(self):
        def failed_matrix(argv, **kwargs):
            if argv[0] == "swiftc":
                return SimpleNamespace(returncode=0, stdout="", stderr="")
            return SimpleNamespace(returncode=17, stdout="matrix stdout", stderr="matrix stderr")

        with self.assertRaisesRegex(harness.HarnessError, "behavior matrix failed"):
            self.invoke(side_effect=failed_matrix)
        log = (self.output / harness.LOG_NAME).read_text(encoding="utf-8")
        self.assertNotIn(harness.SUCCESS_MARKER, log)
        self.assertIn("matrix_returncode=17", log)
        self.assertIn('matrix_stdout="matrix stdout"', log)
        self.assertIn('matrix_stderr="matrix stderr"', log)

    def test_non_signal_trap_exit_records_diagnostics_but_no_success_marker(self):
        def unexpected_exit(argv, **kwargs):
            if argv[0] == "swiftc":
                return SimpleNamespace(returncode=0, stdout="", stderr="")
            if len(argv) == 1:
                return SimpleNamespace(returncode=0, stdout=harness.MATRIX_SENTINEL, stderr="")
            if argv[1] == "--missing-parameter":
                return SimpleNamespace(returncode=1, stdout="", stderr="GETTER_TRAP_MODE:missing-parameter\nordinary failure")
            return SimpleNamespace(returncode=-signal.SIGILL, stdout="",
                                   stderr=f"GETTER_TRAP_MODE:{argv[1][2:]}\nFatal error")

        with self.assertRaisesRegex(harness.HarnessError, "Darwin fatal trap"):
            self.invoke(side_effect=unexpected_exit)
        log = (self.output / harness.LOG_NAME).read_text(encoding="utf-8")
        self.assertNotIn(harness.SUCCESS_MARKER, log)
        self.assertIn("parameter_missing_value_returncode=1", log)
        self.assertIn('parameter_missing_value_stderr="GETTER_TRAP_MODE:missing-parameter\\nordinary failure"', log)

    def test_signal_trap_without_mode_marker_is_rejected(self):
        def missing_marker(argv, **kwargs):
            if argv[0] == "swiftc":
                return SimpleNamespace(returncode=0, stdout="", stderr="")
            if len(argv) == 1:
                return SimpleNamespace(returncode=0, stdout=harness.MATRIX_SENTINEL, stderr="")
            return SimpleNamespace(returncode=-signal.SIGTRAP, stdout="", stderr="unrelated crash")

        with self.assertRaisesRegex(harness.HarnessError, "Darwin fatal trap"):
            self.invoke(side_effect=missing_marker)
        log = (self.output / harness.LOG_NAME).read_text(encoding="utf-8")
        self.assertNotIn(harness.SUCCESS_MARKER, log)
        self.assertIn(f"parameter_missing_value_returncode={-signal.SIGTRAP}", log)

    def test_fixture_emits_each_mode_marker_before_getter_access(self):
        fixture = FIXTURE_PATH.read_text(encoding="utf-8")
        self.assertIn("GETTER_TRAP_MODE:", fixture)
        modes = ("missing-parameter", "missing-module",
                 "negative-control-parameter", "negative-control-module")
        for mode in modes:
            with self.subTest(mode=mode):
                case = fixture.split(f'case "--{mode}":', 1)[1].split("case ", 1)[0]
                self.assertLess(case.index(f'announceTrapMode("{mode}")'), case.index(".wrappedValue"))

    def test_host_guard_rejects_non_arm64_before_process_execution(self):
        with patch.object(harness.platform, "machine", return_value="x86_64"), \
                patch.object(harness.subprocess, "run") as process:
            with self.assertRaisesRegex(harness.HarnessError, "Darwin arm64"):
                harness.run(self.args)
        process.assert_not_called()
        self.assertNotIn(harness.SUCCESS_MARKER,
                         (self.output / harness.LOG_NAME).read_text(encoding="utf-8"))

    def test_getter_extraction_rejects_duplicate_class_declaration(self):
        with self.assertRaisesRegex(harness.HarnessError, "missing or ambiguous"):
            harness._extract_getter(SOURCE + SOURCE, "ParameterInfo")

    def test_each_owned_file_stays_below_size_limit(self):
        for path in (SCRIPT_PATH, FIXTURE_PATH, Path(__file__)):
            with self.subTest(path=path):
                self.assertLessEqual(path.stat().st_size, 16384)


if __name__ == "__main__":
    unittest.main()
