import ast
import copy
import hashlib
import importlib.util
import json
import signal
import shutil
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = ROOT / "scripts/test-mlx-getters.py"
FIXTURE_PATH = ROOT / "scripts/tests/fixtures/MLXGetterCompatibility.swift"
TRUSTED_APPROVAL_PATH = ROOT / "scripts/ci_mlx_approval.py"
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
    tree = ast.parse(TRUSTED_APPROVAL_PATH.read_text(encoding="utf-8"))
    approval = copy.deepcopy(ast.literal_eval(next(
        node.value for node in tree.body if isinstance(node, ast.Assign)
        and len(node.targets) == 1 and getattr(node.targets[0], "id", None) == "MLX_PATCH")))
    spec = next(item for item in approval["files"] if item["path"] == harness.MODULE_PATH)
    spec["patchedSHA256"] = SOURCE_SHA256
    spec["patchedSize"] = len(SOURCE_BYTES)
    return approval


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
        self.approval = approved_patch()
        self.helper = scripts / "patch-mlx-mask-fill.py"
        self.helper.write_text(f"APPROVED_MLX_PATCH = {self.approval!r}\n"
                               "raise AssertionError('executed')\n", encoding="utf-8")
        (scripts / "ci_mlx_approval.py").write_text(f"MLX_PATCH = {self.approval!r}\n"
                                                     "raise AssertionError('executed')\n",
                                                     encoding="utf-8")
        self.output = self.root / "OUT"
        self.work = self.root / "WORK"
        self.args = SimpleNamespace(source_root=self.root, output_dir=self.output, work_dir=self.work)
        anchor = patch.object(harness, "TRUSTED_APPROVAL_ROOT", self.root)
        anchor.start()
        self.addCleanup(anchor.stop)
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
                return SimpleNamespace(returncode=0, stdout=harness.MATRIX_SENTINEL + "\n",
                                       stderr="REFERENCE_MATRIX:Int?:outer nil reference=nil match=true\nmatrix detail\n")
            marker = f"GETTER_TRAP_MODE:{argv[1][2:]}"
            return SimpleNamespace(returncode=-signal.SIGILL, stdout="", stderr=marker + "\nFatal error: expected trap")

        process = side_effect or successful_process
        with patch.object(harness.subprocess, "run", side_effect=process):
            path = harness.run(self.args)
        return path, calls

    def reject(self, approval):
        self.helper.write_text(f"APPROVED_MLX_PATCH = {approval!r}\n", encoding="utf-8")
        with patch.object(harness.subprocess, "run") as process, self.assertRaises(harness.HarnessError):
            harness.run(self.args)
        process.assert_not_called()

    def test_success_provenance(self):
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
        for entry in ('compile_returncode=0', 'compile_stdout="compiler output\\n"',
                      'compile_stderr="compiler diagnostic\\n"', "matrix_returncode=0",
                      'matrix_stdout="GETTER_MATRIX_PASSED\\n"',
                      'matrix_stderr="REFERENCE_MATRIX:Int?:outer nil reference=nil match=true\\nmatrix detail\\n"'):
            self.assertIn(entry, lines)
        for label in ("parameter_missing_value", "module_missing_value",
                      "parameter_negative_control", "module_negative_control", "reference_missing_value"):
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
            "--negative-control-parameter", "--negative-control-module", "--missing-reference",
        ])
        self.assertIn("-warnings-as-errors", compile_argv)
        self.assertFalse(any("suppress" in arg for arg in compile_argv))
        self.assertIn("not an MLX/Metal module acceptance test", log)

    def test_tampered_source_no_compile(self):
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

    def test_replacements_rejected(self):
        for missing in (False, True):
            approval = copy.deepcopy(self.approval)
            replacements = next(item["replacements"] for item in approval["files"]
                                if item["path"] == harness.MODULE_PATH)
            if missing:
                replacements.pop()
            elif len(replacements) > 2:
                replacements[2]["newText"] += " unapproved"
            else:
                replacements.append({"oldText": "third hunk", "newText": "unapproved"})
            with self.subTest(missing=missing):
                self.reject(approval)

    def test_bad_approval_rejected(self):
        for field in ("revision", "license", "originalSHA256", "patchedSHA256"):
            approval = copy.deepcopy(self.approval)
            if field == "license":
                approval[field]["sha256"] = "0" * 64
            elif field in {"originalSHA256", "patchedSHA256"}:
                spec = next(item for item in approval["files"] if item["path"] == harness.MODULE_PATH)
                spec[field] = "0" * 64
            else:
                approval[field] += "-unapproved"
            with self.subTest(field=field):
                self.reject(approval)

    def test_alternate_root_twin_tamper(self):
        self.args.source_root = self.root
        with patch.object(harness, "TRUSTED_APPROVAL_ROOT", ROOT), \
                patch.object(harness.subprocess, "run") as process:
            with self.assertRaisesRegex(harness.HarnessError, "does not match independent approval"):
                harness.run(self.args)
        process.assert_not_called()

    def test_compile_failure_log(self):
        def failed_compile(argv, **kwargs):
            return SimpleNamespace(returncode=1, stdout="compiler stdout", stderr="compile failure")

        with self.assertRaisesRegex(harness.HarnessError, "compilation failed"):
            self.invoke(side_effect=failed_compile)
        log = (self.output / harness.LOG_NAME).read_text(encoding="utf-8")
        self.assertNotIn(harness.SUCCESS_MARKER, log)
        for entry in ("compile_argv=", "compile_returncode=1", 'compile_stdout="compiler stdout"',
                      'compile_stderr="compile failure"'):
            self.assertIn(entry, log)

    def test_matrix_failure_log(self):
        def failed_matrix(argv, **kwargs):
            if argv[0] == "swiftc":
                return SimpleNamespace(returncode=0, stdout="", stderr="")
            return SimpleNamespace(returncode=17, stdout="matrix stdout", stderr="matrix stderr")

        with self.assertRaisesRegex(harness.HarnessError, "behavior matrix failed"):
            self.invoke(side_effect=failed_matrix)
        log = (self.output / harness.LOG_NAME).read_text(encoding="utf-8")
        self.assertNotIn(harness.SUCCESS_MARKER, log)
        for entry in ("matrix_returncode=17", 'matrix_stdout="matrix stdout"',
                      'matrix_stderr="matrix stderr"'):
            self.assertIn(entry, log)

    def test_matrix_output_contract(self):
        def noisy_matrix(argv, **kwargs):
            if argv[0] == "swiftc":
                return SimpleNamespace(returncode=0, stdout="", stderr="")
            return SimpleNamespace(returncode=0, stdout=harness.MATRIX_SENTINEL + "\nextra\n",
                                   stderr="REFERENCE_MATRIX:Int?:outer nil\n")

        with self.assertRaisesRegex(harness.HarnessError, "matrix output or reference diagnostics"):
            self.invoke(side_effect=noisy_matrix)
        log = (self.output / harness.LOG_NAME).read_text(encoding="utf-8")
        self.assertNotIn(harness.SUCCESS_MARKER, log)
        self.assertIn('matrix_stdout="GETTER_MATRIX_PASSED\\nextra\\n"', log)

    def test_fixture_oracle_and_depths(self):
        fixture = FIXTURE_PATH.read_text(encoding="utf-8")
        for fragment in ("referenceCast<Source, Destination>", "@inline(never)\nprivate func referenceCast",
                         "value as? Destination", "referenceGetter<T>",
                         "_ = referenceGetter(nil as Int?)"):
            self.assertIn(fragment, fixture)
        self.assertNotIn("referenceGetter<Int>", fixture)
        self.assertIn("REFERENCE_MATRIX:", fixture)
        for case in ("Int?", "Int??", "ReferenceValue?", "ReferenceValue??",
                     "outer nil", "middle nil", "inner nil", "identity"):
            with self.subTest(case=case):
                self.assertIn(case, fixture)
        self.assertIn("let depthOne: Int????", fixture)
        self.assertIn("let depthFour: Int???? = .none", fixture)

    def test_nonsignal_trap_log(self):
        def unexpected_exit(argv, **kwargs):
            if argv[0] == "swiftc":
                return SimpleNamespace(returncode=0, stdout="", stderr="")
            if len(argv) == 1:
                return SimpleNamespace(returncode=0, stdout=harness.MATRIX_SENTINEL + "\n",
                                       stderr="REFERENCE_MATRIX:Int?:outer nil\n")
            if argv[1] == "--missing-parameter":
                return SimpleNamespace(returncode=1, stdout="", stderr="GETTER_TRAP_MODE:missing-parameter\nordinary failure")
            return SimpleNamespace(returncode=-signal.SIGILL, stdout="",
                                   stderr=f"GETTER_TRAP_MODE:{argv[1][2:]}\nFatal error")

        with self.assertRaisesRegex(harness.HarnessError, "Darwin fatal trap"):
            self.invoke(side_effect=unexpected_exit)
        log = (self.output / harness.LOG_NAME).read_text(encoding="utf-8")
        self.assertNotIn(harness.SUCCESS_MARKER, log)
        for entry in ("parameter_missing_value_returncode=1",
                      'parameter_missing_value_stderr="GETTER_TRAP_MODE:missing-parameter\\nordinary failure"'):
            self.assertIn(entry, log)

    def test_signal_trap_requires_marker(self):
        def missing_marker(argv, **kwargs):
            if argv[0] == "swiftc":
                return SimpleNamespace(returncode=0, stdout="", stderr="")
            if len(argv) == 1:
                return SimpleNamespace(returncode=0, stdout=harness.MATRIX_SENTINEL + "\n",
                                       stderr="REFERENCE_MATRIX:Int?:outer nil\n")
            return SimpleNamespace(returncode=-signal.SIGTRAP, stdout="", stderr="unrelated crash")

        with self.assertRaisesRegex(harness.HarnessError, "Darwin fatal trap"):
            self.invoke(side_effect=missing_marker)
        log = (self.output / harness.LOG_NAME).read_text(encoding="utf-8")
        self.assertNotIn(harness.SUCCESS_MARKER, log)
        self.assertIn(f"parameter_missing_value_returncode={-signal.SIGTRAP}", log)

    def test_trap_markers_precede_access(self):
        fixture = FIXTURE_PATH.read_text(encoding="utf-8")
        self.assertIn("GETTER_TRAP_MODE:", fixture)
        modes = ("missing-reference", "missing-parameter", "missing-module",
                 "negative-control-parameter", "negative-control-module")
        for mode in modes:
            with self.subTest(mode=mode):
                case = fixture.split(f'case "--{mode}":', 1)[1].split("case ", 1)[0]
                access = "referenceGetter" if mode == "missing-reference" else ".wrappedValue"
                self.assertLess(case.index(f'announceTrapMode("{mode}")'), case.index(access))

    def test_host_guard_before_process(self):
        with patch.object(harness.platform, "machine", return_value="x86_64"), \
                patch.object(harness.subprocess, "run") as process:
            with self.assertRaisesRegex(harness.HarnessError, "Darwin arm64"):
                harness.run(self.args)
        process.assert_not_called()
        self.assertNotIn(harness.SUCCESS_MARKER,
                         (self.output / harness.LOG_NAME).read_text(encoding="utf-8"))

    def test_duplicate_getter_class_rejected(self):
        with self.assertRaisesRegex(harness.HarnessError, "missing or ambiguous"):
            harness._extract_getter(SOURCE + SOURCE, "ParameterInfo")

    def test_each_owned_file_stays_below_size_limit(self):
        for path in (SCRIPT_PATH, FIXTURE_PATH, Path(__file__)):
            with self.subTest(path=path):
                self.assertLessEqual(path.stat().st_size, 16384)


if __name__ == "__main__":
    unittest.main()
