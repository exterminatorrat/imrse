import hashlib
import json
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from scripts.tests import test_import_ci_candidate as fixture
from scripts.tests.test_mlx_candidate_provenance import exporter


class MLXGetterArtifactTests(unittest.TestCase):
    def test_export_requires_a_terminal_getter_success_marker(self):
        for contents in (None, b"", b"failed\n", b"MLX getter compatibility checks passed.\nfailed\n"):
            with self.subTest(contents=contents), tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary)
                (output / exporter.MLX_CONTROL_FLOW_LOG).write_text(exporter.MLX_CONTROL_FLOW_MARKER + "\n")
                (output / exporter.MLX_BUILD_INPUTS).write_text("[]\n")
                if contents is not None:
                    (output / exporter.ci_approval.GETTER_LOG).write_bytes(contents)
                with self.assertRaises(exporter.ExportError):
                    exporter.mlx_qualification(output)

    def test_import_rejects_missing_tampered_and_falsely_completed_getter_evidence(self):
        importer = fixture.importer
        name = importer.ci_approval.GETTER_LOG
        field = "mlxGetterCompatibilityTestLogSHA256"
        for case in ("missing log", "missing digest", "wrong digest", "tampered log", "empty log", "failure after marker"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary)
                artifact, root = fixture.make(base)
                with zipfile.ZipFile(artifact) as archive:
                    members = {entry.filename: archive.read(entry) for entry in archive.infolist()}
                manifest = json.loads(members[importer.M])
                if case == "missing log":
                    members.pop(name)
                elif case == "missing digest":
                    manifest["dependencies"].pop(field)
                elif case == "wrong digest":
                    manifest["dependencies"][field] = "0" * 64
                else:
                    members[name] = {
                        "tampered log": b"tampered\n",
                        "empty log": b"",
                        "failure after marker": b"MLX getter compatibility checks passed.\nfailed\n",
                    }[case]
                    if case != "tampered log":
                        manifest["dependencies"][field] = hashlib.sha256(members[name]).hexdigest()
                members[importer.M] = json.dumps(manifest).encode()
                changed = base / "changed.zip"
                with zipfile.ZipFile(changed, "w") as archive:
                    for member, data in members.items():
                        archive.writestr(member, data)
                with patch.object(importer, "git_id", return_value=(fixture.COMMIT, fixture.TREE)), \
                     patch.object(importer, "approved_extensions", return_value=fixture.EXTENSIONS), \
                     patch.object(importer, "approved_patch", return_value=fixture.APPROVED_PATCH), \
                     patch.object(importer, "approved_mlx_patch", return_value=fixture.MLX_PATCH):
                    with self.assertRaises(importer.CandidateError):
                        importer.import_candidate(changed, fixture.sha256(changed.read_bytes()), root,
                                                  fixture.COMMIT, fixture.TREE, "1234", "2", base / "out")
                self.assertFalse((base / "out").exists())

    def test_workflow_compiles_and_accounts_for_both_approved_mlx_sources(self):
        workflow = (fixture.ROOT / ".github/workflows/verify.yml").read_text()
        self.assertIn('("MLX", "MLXNN")', workflow)
        self.assertIn('if len(targets) != len(approval["files"]):', workflow)
        self.assertLess(workflow.index("scripts/test-mlx-getters.py"), workflow.index("id: ci-build"))
        self.assertIn('--work-dir "$RUNNER_TEMP/mlx-getters"', workflow)
