import hashlib
import importlib.util
import io
import json
import sys
import tarfile
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import ci_approval

EXPORT_SPEC = importlib.util.spec_from_file_location("export_ci_candidate", ROOT / "scripts/export-ci-candidate.py")
exporter = importlib.util.module_from_spec(EXPORT_SPEC)
EXPORT_SPEC.loader.exec_module(exporter)
IMPORT_SPEC = importlib.util.spec_from_file_location("import_ci_candidate", ROOT / "scripts/import-ci-candidate.py")
importer = importlib.util.module_from_spec(IMPORT_SPEC)
IMPORT_SPEC.loader.exec_module(importer)

LICENSE = b"synthetic MLX license for candidate provenance tests\n"
MLX_PATCH = {
    "schemaVersion": 1,
    "identity": "mlx-swift",
    "version": "0.31.6",
    "url": "https://github.com/ml-explore/mlx-swift",
    "revision": "0bb916c67f4b9e5c682cbe02a42c701c93ab5021",
    "license": {"path": "LICENSE", "sha256": hashlib.sha256(LICENSE).hexdigest()},
    "files": [{
        "path": "Source/MLX/MLXArray+maskFill.swift",
        "originalSHA256": "a" * 64,
        "patchedSHA256": "b" * 64,
        "originalSize": 495,
        "patchedSize": 491,
        "oldText": "guard let info = dtype.finfo else {",
        "newText": "guard dtype.finfo != nil else {",
    }],
}
MLX_RAW = (json.dumps(MLX_PATCH, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()


def record(data):
    return {"type": "file", "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def app_inventory(receipt=MLX_RAW, license_data=LICENSE):
    return {
        ci_approval.MLX_APP_RECEIPT: record(receipt),
        ci_approval.MLX_APP_LICENSE: record(license_data),
    }


def preflight_archive(parser_receipt, mlx_receipt, license_data):
    archive = tempfile.TemporaryFile()
    with tarfile.open(fileobj=archive, mode="w:gz") as tar:
        for name, data in (
            ("imrse.app/" + ci_approval.PATCH_APP_RECEIPT, parser_receipt),
            ("imrse.app/" + ci_approval.MLX_APP_RECEIPT, mlx_receipt),
            ("imrse.app/" + ci_approval.MLX_APP_LICENSE, license_data),
        ):
            member = tarfile.TarInfo(name)
            member.size = len(data)
            tar.addfile(member, io.BytesIO(data))
    archive.seek(0)
    return archive


class MLXCandidateProvenanceTests(unittest.TestCase):
    def test_importer_keeps_shared_approval_aliases_for_fixture_mocking(self):
        self.assertIs(importer.approved_mlx_patch, ci_approval.approved_mlx_patch)
        self.assertIs(importer.approved_extensions, ci_approval.approved_extensions)

    def test_approved_literal_is_read_as_ast_data_without_execution(self):
        source = f"APPROVED_MLX_PATCH = {ci_approval.MLX_PATCH!r}\nraise RuntimeError('must not run')\n"
        with patch.object(ci_approval.subprocess, "check_output", return_value=source) as show:
            self.assertEqual(ci_approval.approved_mlx_patch(Path("/source"), "a" * 40), ci_approval.MLX_PATCH)
        self.assertEqual(
            show.call_args.args[0][-1],
            "a" * 40 + ":scripts/patch-mlx-mask-fill.py",
        )

    def test_approval_rejects_wrong_pin_scope_hunk_license_and_sizes(self):
        cases = {
            "revision": lambda value: value.update(revision="0" * 40),
            "scope": lambda value: value.update(extraChange=True),
            "hunk": lambda value: value["files"][0].update(newText="guard let info = dtype.finfo else {"),
            "license": lambda value: value["license"].update(sha256="0" * 64),
            "size": lambda value: value["files"][0].update(originalSize=494),
            "schema type": lambda value: value.update(schemaVersion=True),
            "missing getters": lambda value: value["files"].pop(),
            "getter hunk": lambda value: value["files"][1]["replacements"][0].update(newText="return value!"),
            "getter bytes": lambda value: value["files"][1].update(patchedSHA256="0" * 64),
        }
        for name, mutate in cases.items():
            with self.subTest(case=name):
                changed = json.loads(json.dumps(ci_approval.MLX_PATCH))
                mutate(changed)
                with patch.object(ci_approval, "committed_literal", return_value=changed):
                    with self.assertRaises(ValueError):
                        ci_approval.approved_mlx_patch(Path("/source"), "a" * 40)

    def test_export_proof_accepts_canonical_receipt_and_upstream_license(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            license_path = root / ".build/checkouts/mlx-swift/LICENSE"
            license_path.parent.mkdir(parents=True)
            license_path.write_bytes(LICENSE)
            bundle = root / "imrse.app"
            resources = bundle / "Contents/Resources/ThirdPartyLicenses"
            resources.mkdir(parents=True)
            (resources / "mlx-swift-COMPATIBILITY.json").write_bytes(MLX_RAW)
            (resources / "mlx-swift-LICENSE").write_bytes(LICENSE)
            receipt = root / "mlx-mask-fill-compatibility.json"
            receipt.write_bytes(MLX_RAW)
            args = SimpleNamespace(mlx_mask_fill_patch_receipt=receipt)
            entries = [{"path": path, **value} for path, value in app_inventory().items()]
            with patch.object(exporter, "approved_mlx_patch", return_value=MLX_PATCH):
                self.assertEqual(exporter.mlx_patch_proof(args, root, bundle, "a" * 40, entries),
                                 (MLX_PATCH, MLX_RAW))

    def test_export_proof_rejects_missing_tampered_embedded_and_license_proofs(self):
        cases = ("missing", "tampered", "embedded", "upstream license", "app license", "inventory license")
        for case in cases:
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                license_path = root / ".build/checkouts/mlx-swift/LICENSE"
                license_path.parent.mkdir(parents=True)
                license_path.write_bytes(b"altered license\n" if case == "upstream license" else LICENSE)
                bundle = root / "imrse.app"
                resources = bundle / "Contents/Resources/ThirdPartyLicenses"
                resources.mkdir(parents=True)
                embedded = b"tampered receipt\n" if case == "embedded" else MLX_RAW
                app_license = b"tampered app license\n" if case == "app license" else LICENSE
                (resources / "mlx-swift-COMPATIBILITY.json").write_bytes(embedded)
                (resources / "mlx-swift-LICENSE").write_bytes(app_license)
                receipt = root / "mlx-mask-fill-compatibility.json"
                if case != "missing":
                    receipt.write_bytes(b"tampered sidecar\n" if case == "tampered" else MLX_RAW)
                inventory = app_inventory()
                entries = [{"path": path, **value} for path, value in inventory.items()]
                if case == "inventory license":
                    entries[1]["sha256"] = "0" * 64
                args = SimpleNamespace(mlx_mask_fill_patch_receipt=receipt)
                with patch.object(exporter, "approved_mlx_patch", return_value=MLX_PATCH):
                    with self.assertRaises((exporter.ExportError, OSError)):
                        exporter.mlx_patch_proof(args, root, bundle, "a" * 40, entries)

    def test_control_flow_log_marker_and_build_inputs_are_required(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            log = output / exporter.MLX_CONTROL_FLOW_LOG
            inputs = output / exporter.MLX_BUILD_INPUTS
            getters = output / ci_approval.GETTER_LOG
            getters.write_text("MLX getter compatibility checks passed.\n")
            log.write_text("valid and invalid DType branches passed.\n" + exporter.MLX_CONTROL_FLOW_MARKER + "\n")
            inputs.write_text('{"command": ["swiftc"], "sources": ["Source/MLX/MLXArray+maskFill.swift"]}\n')
            expected = tuple(hashlib.sha256(path.read_bytes()).hexdigest() for path in (log, inputs, getters))
            self.assertEqual(exporter.mlx_qualification(output), expected)
            log.write_text("MLX mask-fill control-flow checks failed.\n")
            with self.assertRaises(exporter.ExportError):
                exporter.mlx_qualification(output)
            log.write_text(exporter.MLX_CONTROL_FLOW_MARKER + "\n")
            inputs.write_bytes(b"")
            with self.assertRaises(exporter.ExportError):
                exporter.mlx_qualification(output)

    def test_import_receipt_validation_binds_digest_inventory_and_license(self):
        inventory = app_inventory()
        dependencies = {"mlxMaskFillPatchReceiptSHA256": hashlib.sha256(MLX_RAW).hexdigest()}
        self.assertEqual(ci_approval.validate_mlx_receipt(MLX_PATCH, MLX_RAW, dependencies, inventory),
                         MLX_PATCH["license"]["sha256"])
        failures = (
            (MLX_RAW + b" ", dependencies, inventory),
            (MLX_RAW, {"mlxMaskFillPatchReceiptSHA256": "0" * 64}, inventory),
            (MLX_RAW, dependencies, app_inventory(license_data=b"tampered license")),
            (MLX_RAW, dependencies, app_inventory(receipt=b"tampered receipt")),
        )
        for receipt, digests, entries in failures:
            with self.subTest(receipt=receipt[-8:], digest=digests):
                with self.assertRaises(ValueError):
                    ci_approval.validate_mlx_receipt(MLX_PATCH, receipt, digests, entries)

    def test_export_cli_requires_an_explicit_mlx_receipt_path(self):
        stderr = io.StringIO()
        arguments = ["--source-root", "/source", "--expected-commit", "a" * 40,
                     "--graph-json", "/graph", "--eventsource-test-log", "/tests",
                     "--argument-parser-patch-receipt", "/parser-receipt"]
        with redirect_stderr(stderr), self.assertRaises(SystemExit) as error:
            exporter.main(arguments)
        self.assertEqual(error.exception.code, 2)
        self.assertIn("--mlx-mask-fill-patch-receipt", stderr.getvalue())

    def test_tar_preflight_matches_both_embedded_receipts_and_pinned_license(self):
        parser_receipt = b"argument parser receipt\n"
        archive = preflight_archive(parser_receipt, MLX_RAW, LICENSE)
        with archive:
            ci_approval.preflight_candidate_archive(archive, parser_receipt, MLX_RAW,
                                                    MLX_PATCH["license"]["sha256"], 10, 1024 * 1024)
        for embedded_receipt, license_data in (
            (parser_receipt, b"wrong MLX receipt\n"),
            (parser_receipt, b"wrong license\n"),
        ):
            with self.subTest(license=license_data):
                archive = preflight_archive(parser_receipt, embedded_receipt, license_data)
                with archive:
                    with self.assertRaises(ValueError):
                        ci_approval.preflight_candidate_archive(archive, parser_receipt, MLX_RAW,
                                                                MLX_PATCH["license"]["sha256"], 10, 1024 * 1024)


if __name__ == "__main__":
    unittest.main()
