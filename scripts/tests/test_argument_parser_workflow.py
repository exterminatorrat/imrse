import json
import hashlib
import os
import tempfile
import textwrap
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]


class ArgumentParserWorkflowTests(unittest.TestCase):
    def step(self):
        workflow = (ROOT / ".github/workflows/verify.yml").read_text()
        return workflow.split("- name: Verify legacy ArgumentParser behavior with strict warnings\n", 1)[1].split(
            "      - name:", 1
        )[0]

    def programs(self):
        return [textwrap.dedent(part.split("          PY\n", 1)[0])
                for part in self.step().split("python3 - <<'PY'\n")[1:]]

    def test_patch_and_behavior_checks_precede_extension_enablement_and_build(self):
        workflow = (ROOT / ".github/workflows/verify.yml").read_text()
        positions = [workflow.index(name) for name in (
            "Resolve the root graph from the frozen lock",
            "Apply the exact two-annotation CI-only compatibility exception",
            "Verify legacy ArgumentParser behavior with strict warnings",
            "Enable only the two reviewed revision-bound extensions",
            "Apply the exact MLX compatibility repairs after pristine extension validation",
            "Verify the exact patched MLX guard control flow without Metal",
            "Verify exact MLX getters preserve nested optional values and traps",
            "Build the unsigned CI app with one scheduler job and WMO frontend thread",
        )]
        self.assertEqual(positions, sorted(positions))
        self.assertEqual(self.step().count("-Xswiftc -warnings-as-errors"), 2)
        self.assertIn("--verify-only", self.step())
        self.assertIn('--argument-parser-patch-receipt "$IMRSE_CI_CANDIDATE_DIR/argument-parser-compatibility.json"', workflow)
        script = (ROOT / "scripts/build-app.sh").read_text()
        self.assertLess(script.index('  "${BUILD_COMMAND[@]}"\n'), script.index('"$ROOT/scripts/patch-argument-parser.py"'))
        self.assertLess(script.index('"$ROOT/scripts/patch-argument-parser.py"'), script.index('BIN="$SCRATCH_PATH/ci-derived-data'))
        self.assertLess(script.index('"$THIRD_PARTY_LICENSES/swift-argument-parser-COMPATIBILITY.json"'),
                        script.index('validate-ci-app \\'))

    def test_fixture_manifest_selects_only_the_owned_patched_checkout(self):
        program = self.programs()[0]
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / "scripts/tests/fixtures/ArgumentParserCompatibility.swift"
            source.parent.mkdir(parents=True)
            source.write_text('print("synthetic fixture")\n')
            checkout = base / ".build/checkouts/swift-argument-parser"
            checkout.mkdir(parents=True)
            runner = base / "runner"
            runner.mkdir()
            previous = Path.cwd()
            try:
                os.chdir(base)
                with patch.dict(os.environ, RUNNER_TEMP=str(runner)):
                    exec(program, {})
            finally:
                os.chdir(previous)
            fixture = runner / "argument-parser-compatibility"
            manifest = (fixture / "Package.swift").read_text()
            self.assertIn(f'.package(path: {json.dumps(str(checkout.resolve()))})', manifest)
            self.assertIn('.product(name: "ArgumentParser", package: "swift-argument-parser")', manifest)
            self.assertNotIn("https://", manifest)
            self.assertEqual((fixture / "Sources/ArgumentParserCompatibility/main.swift").read_bytes(), source.read_bytes())

    def test_dump_snapshot_marker_requires_exact_original_serialized_values(self):
        program = self.programs()[1]
        for mismatch in (False, True):
            with self.subTest(mismatch=mismatch), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary)
                output = base / "output"
                output.mkdir()
                snapshot = base / ".build/checkouts/swift-argument-parser/Tests/ArgumentParserUnitTests/Snapshots/testMathDumpHelp().json"
                snapshot.parent.mkdir(parents=True)
                snapshot.write_text('{"customDeprecated": {}}')
                actual = output / "argument-parser-dump-help.json"
                actual.write_text('{"custom": {}}' if mismatch else snapshot.read_text())
                previous = Path.cwd()
                try:
                    os.chdir(base)
                    with patch.dict(os.environ, IMRSE_CI_CANDIDATE_DIR=str(output)):
                        if mismatch:
                            with self.assertRaisesRegex(SystemExit, "pinned upstream snapshot"):
                                exec(program, {})
                        else:
                            exec(program, {})
                finally:
                    os.chdir(previous)
                log = output / "argument-parser-compatibility-tests.log"
                self.assertEqual(log.exists(), not mismatch)
                if not mismatch:
                    self.assertEqual(log.read_text(), "ArgumentParser compatibility checks passed.\n")

    def test_consumption_proof_requires_the_actual_compiler_list_and_patched_bytes(self):
        workflow = (ROOT / ".github/workflows/verify.yml").read_text()
        step = workflow.split("- name: Build the unsigned CI app with one scheduler job and WMO frontend thread\n", 1)[1].split(
            "      - name: Retain and check the RealModule", 1)[0]
        program = textwrap.dedent(step.split("python3 - <<'PY'\n", 1)[1].split("          PY\n", 1)[0])
        for missing_command, wrong_bytes in ((False, False), (True, False), (False, True)):
            with self.subTest(missing_command=missing_command, wrong_bytes=wrong_bytes), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary).resolve()
                output = base / "output"
                output.mkdir()
                sources, commands = {"swift-argument-parser": [], "mlx-swift": []}, []
                for identity, target in (("swift-argument-parser", "ArgumentParser"),
                                         ("swift-argument-parser", "ArgumentParserToolInfo"),
                                         ("mlx-swift", "MLX"), ("mlx-swift", "MLXNN")):
                    relative = f"Sources/{target}/source with spaces.swift"
                    source = base / ".build/checkouts" / identity / relative
                    source.parent.mkdir(parents=True)
                    source.write_bytes(b"patched fixture")
                    sources[identity].append({"path": relative, "patchedSHA256": hashlib.sha256(source.read_bytes()).hexdigest()})
                    filelist = base / f".build/ci-derived-data/Build/Intermediates.noindex/{identity}.build/Release/{target}.build/Objects-normal/arm64/{target}.SwiftFileList"
                    filelist.parent.mkdir(parents=True)
                    filelist.write_text(json.dumps(str(source)) + "\n")
                    commands.append(f'builtin-SwiftDriver -- swiftc -module-name {target} @{filelist}')
                    if wrong_bytes:
                        source.write_bytes(b"unexpected source")
                (base / "scripts").mkdir()
                for helper, constant, identity in (("patch-argument-parser.py", "APPROVED_PATCH", "swift-argument-parser"),
                                                   ("patch-mlx-mask-fill.py", "APPROVED_MLX_PATCH", "mlx-swift")):
                    (base / "scripts" / helper).write_text(constant + " = " + repr({"identity": identity, "files": sources[identity]}))
                (output / "build.log").write_text("\n".join(commands[1:] if missing_command else commands))
                previous = Path.cwd()
                try:
                    os.chdir(base)
                    with patch.dict(os.environ, IMRSE_CI_CANDIDATE_DIR=str(output)):
                        if missing_command or wrong_bytes:
                            with self.assertRaises(SystemExit):
                                exec(program, {})
                        else:
                            exec(program, {})
                finally:
                    os.chdir(previous)
                proof = output / "argument-parser-build-inputs.json"
                self.assertEqual(proof.exists(), not (missing_command or wrong_bytes))
                if proof.exists():
                    self.assertEqual(len(json.loads(proof.read_text())), 2)
                    self.assertEqual(len(json.loads((output / "mlx-mask-fill-build-inputs.json").read_text())), 2)

    def test_mlx_control_flow_marker_requires_valid_and_expected_fatal_paths(self):
        workflow = (ROOT / ".github/workflows/verify.yml").read_text()
        step = workflow.split("- name: Verify the exact patched MLX guard control flow without Metal\n", 1)[1].split(
            "      - name:", 1)[0]
        self.assertIn("swiftc -parse-as-library -swift-version 6 -warnings-as-errors", step)
        self.assertIn(".build/checkouts/mlx-swift/Source/MLX/MLXArray+maskFill.swift", step)
        program = textwrap.dedent(step.split("python3 - <<'PY'\n", 1)[1].split("          PY\n", 1)[0])
        expected_error = b"maskFill requires a floating-point dtype, got int32"
        for valid_code, invalid_code, stderr in ((0, -5, expected_error), (1, -5, expected_error),
                                                  (0, 0, expected_error), (0, -5, b"wrong fatal branch"),
                                                  (0, -5, expected_error + b"unexpected greatestFiniteMagnitudeArray")):
            with self.subTest(valid_code=valid_code, invalid_code=invalid_code, stderr=stderr), tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary)
                accepted = valid_code == 0 and invalid_code != 0 and stderr == expected_error
                results = (SimpleNamespace(returncode=valid_code, stdout=b"", stderr=b""),
                           SimpleNamespace(returncode=invalid_code, stdout=b"", stderr=stderr))
                with patch.dict(os.environ, RUNNER_TEMP=str(output), IMRSE_CI_CANDIDATE_DIR=str(output)), patch(
                    "subprocess.run", side_effect=results):
                    if accepted:
                        exec(program, {})
                    else:
                        with self.assertRaisesRegex(SystemExit, "control-flow fixture failed"):
                            exec(program, {})
                log = (output / "mlx-mask-fill-control-flow-tests.log").read_text()
                self.assertEqual(log.endswith("MLX mask-fill control-flow checks passed.\n"), accepted)


if __name__ == "__main__":
    unittest.main()
