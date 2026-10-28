import importlib.util
import json
import os
import sys
import tarfile
import tempfile
import textwrap
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("export_ci_candidate", ROOT / "scripts/export-ci-candidate.py")
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)


class ExportCICandidateTests(unittest.TestCase):
    def test_workflow_graph_accepts_only_owned_local_nodes_and_pinned_remote(self):
        workflow = (ROOT / ".github/workflows/verify.yml").read_text()
        gate = textwrap.dedent(workflow.split("python3 - <<'PY'\n", 1)[1].split("          PY\n", 1)[0])
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "Package.resolved").write_text(json.dumps({"pins": []}))
            log = "\n".join(f"Test {title} {event}." for title in exporter.TESTS.values() for event in ("started", "passed"))
            (root / "eventsource-tests.log").write_text(log)
            graph = {"path": str(root), "url": str(root), "dependencies": [
                {"path": str(root / "pill-kit/native"), "url": "local"},
                {"path": str(root / "Vendor/EventSource"), "name": "EventSource"}]}
            graph_path = root / "root-effective-dependency-graph.json"
            with patch("pathlib.Path.cwd", return_value=root), patch.dict(os.environ, IMRSE_CI_CANDIDATE_DIR=str(root)), patch("subprocess.check_output", return_value=""):
                graph_path.write_text(json.dumps(graph))
                exec(gate, {})
                graph["dependencies"].append({"path": str(root / "foreign"), "url": "remote"})
                graph_path.write_text(json.dumps(graph))
                with self.assertRaisesRegex(SystemExit, "outside .build/checkouts"):
                    exec(gate, {})

    def test_source_requires_selected_commit_and_clean_checkout(self):
        commit, tree = "a" * 40, "b" * 40
        with patch.object(exporter, "git", side_effect=(commit, tree, "")):
            self.assertEqual(exporter.source(Path("/source"), commit), (commit, tree))
        with patch.object(exporter, "git", side_effect=(commit, tree, " M Sources/changed.swift")):
            with self.assertRaisesRegex(exporter.ExportError, "source checkout changed"):
                exporter.source(Path("/source"), commit)
        with patch.object(exporter, "git", return_value="c" * 40):
            with self.assertRaisesRegex(exporter.ExportError, "selected workflow SHA"):
                exporter.source(Path("/source"), commit)

    def make_bundle(self, base):
        root = base / "source"
        (root / "Resources").mkdir(parents=True)
        (root / "Resources/Info.plist").write_bytes((ROOT / "Resources/Info.plist").read_bytes())
        (root / "Package.resolved").write_text('{"pins": []}\n')
        vendor = root / "Vendor/EventSource"
        vendor.mkdir(parents=True)
        (vendor / "LICENSE.md").write_text("EventSource license\n")
        (vendor / "PROVENANCE.md").write_text("EventSource provenance\n")
        app = base / "imrse.app"
        resources = app / "Contents/Resources"
        executable = app / "Contents/MacOS/imrse"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"fixture executable")
        executable.chmod(0o755)
        (app / "Contents/Info.plist").write_bytes((root / "Resources/Info.plist").read_bytes())
        (resources / "Brand").mkdir(parents=True)
        (resources / "Brand/imrse-menubar-template.pdf").write_bytes(b"menu")
        (resources / "shaders").mkdir()
        (resources / "shaders/default.metallib").write_bytes(b"metal")
        qwen = resources / "imrse_ImrseLocal.bundle/Contents/Resources/Qwen3-APACHE-LICENSE.txt"
        qwen.parent.mkdir(parents=True)
        qwen.write_bytes(b"Qwen license")
        licenses = resources / "ThirdPartyLicenses"
        licenses.mkdir()
        (licenses / "EventSource-LICENSE.md").write_bytes((vendor / "LICENSE.md").read_bytes())
        (licenses / "EventSource-PROVENANCE.md").write_bytes((vendor / "PROVENANCE.md").read_bytes())
        receipt = {
            "validationMode": "unsigned-ci-package-validation-only", "distributionEligible": False,
            "codeSigningPerformed": False, "releaseBuildProvenanceCreated": False,
            "source": {"commitSHA": "a" * 40, "treeSHA": "b" * 40},
            "product": {"hostArchitecture": "arm64", "machoArchitectures": {"Contents/MacOS/imrse": "arm64"}},
        }
        (resources / exporter.RECEIPT).write_text(json.dumps(receipt))
        return root, app, receipt

    def test_archive_keeps_bundle_modes_and_validation_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root, app, receipt = self.make_bundle(base)
            output = base / "output"
            output.mkdir()
            graph, tests, build, swift, xcode = [base / name for name in ("graph.json", "tests.log", "build.log", "swift.txt", "xcode.txt")]
            graph.write_text("{}")
            tests.write_text("fixture test log")
            build.write_text("fixture build log")
            swift.write_text("Swift version fixture")
            xcode.write_text("Xcode fixture")
            args = SimpleNamespace(app=app, output_dir=output, expected_commit="a" * 40, graph_json=graph,
                                   eventsource_test_log=tests, build_log=build, swift_version_log=swift,
                                   xcode_version_log=xcode)
            exporter.export(args, root, "a" * 40, "b" * 40, 3)
            archive = output / "imrse-ci-candidate-arm64.tar.gz"
            with tarfile.open(archive, "r:gz") as tar:
                executable = tar.getmember("imrse.app/Contents/MacOS/imrse")
                embedded = json.load(tar.extractfile("imrse.app/Contents/Resources/CI-PACKAGE-VALIDATION.json"))
            self.assertEqual(executable.mode, 0o755)
            self.assertEqual(embedded, receipt)
            provenance = json.loads((output / "candidate-provenance.json").read_text())
            self.assertEqual(provenance["source"]["commitSHA"], "a" * 40)
            self.assertEqual(provenance["host"]["minimumMacOS"], "14.0")
            inventory = {item["path"]: item for item in provenance["app"]["inventory"]}
            self.assertEqual(inventory["Contents/MacOS/imrse"]["mode"], 0o755)
            self.assertTrue(inventory["Contents/MacOS/imrse"]["sha256"])
            self.assertEqual(provenance["archive"]["sha256"], exporter.package.sha256_file(archive))
            self.assertIn("not distribution eligible", provenance["scope"])

    def test_missing_shader_fails_before_archive(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root, app, _ = self.make_bundle(base)
            (app / "Contents/Resources/shaders/default.metallib").unlink()
            with self.assertRaisesRegex(exporter.ExportError, "default.metallib"):
                exporter.app_bundle(app, root, "a" * 40, "b" * 40)

    def test_eventsource_test_log_requires_all_three_concrete_tests(self):
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "tests.log"
            log.write_text("\n".join(line for title in exporter.TESTS.values()
                                     for line in (f"◇ Test {title} started.", f"✔ Test {title} passed.")))
            self.assertEqual(exporter.test_count(log), 3)
            log.write_text(log.read_text().replace("Closing from open before byte consumption suppresses late callbacks passed.", ""))
            with self.assertRaisesRegex(exporter.ExportError, "closeFromOpenPreventsLateCallbacks"):
                exporter.test_count(log)


if __name__ == "__main__":
    unittest.main()
