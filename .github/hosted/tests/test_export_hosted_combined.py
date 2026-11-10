import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("export_hosted_combined", Path(__file__).resolve().parents[1] / "export_hosted_combined.py")
exporter = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(exporter)
CONTROL = "1" * 40
RUN = "42"
ATTEMPT = "1"


def passed_result():
    return {
        "status": "passed",
        "sourceCommit": exporter.SOURCE_COMMIT,
        "sourceTree": exporter.SOURCE_TREE,
        "controlCommit": CONTROL,
        "source": {"commitSHA": exporter.SOURCE_COMMIT, "treeSHA": exporter.SOURCE_TREE, "clean": True},
        "control": {"commitSHA": CONTROL, "treeSHA": "2" * 40, "clean": True},
        "run": {"GITHUB_RUN_ID": RUN, "GITHUB_RUN_ATTEMPT": ATTEMPT},
        "admissions": [
            {"phase": name, "requiredFloorBytes": floor * 1024**3, "issues": [], "resources": {"complete": True, "filesystemAvailableBytes": 20 * 1024**3, "actualAPFSFreeBytes": 20 * 1024**3, "memoryPressure": "1", "swapUsedBytes": 0}}
            for name, floor in (("pre-dependency", 16), ("pre-compiler", 16), ("post-build", 12))
        ],
        "phases": [
            {
                "name": name,
                "exitCode": 0,
                "primaryFailure": None,
                "cleanupFailures": [],
                "resourceViolations": [],
                "groupEscapes": [],
                "outputTruncated": False,
                "resourceSamples": 2,
                "firstResource": {"complete": True, "filesystemAvailableBytes": 20 * 1024**3},
                "closure": {"complete": True, "rootReaped": True, "signalAuthorityRetired": True, "remaining": [], "groupMembers": [], "escapes": [], "observedOnly": True},
            }
            for name in ("resolve", "build", "retention")
        ],
    }


class ExportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.evidence = self.root / "evidence"
        self.evidence.mkdir()
        self.output = self.root / "public"

    def tearDown(self):
        self.temporary.cleanup()

    def write_result(self, result):
        (self.evidence / "hosted-combined-result.json").write_text(json.dumps(result))

    def read_receipt(self):
        return json.loads((self.output / "receipts/hosted-combined-receipt.json").read_text())

    def run_export(self):
        return exporter.export(self.evidence, self.output, CONTROL, RUN, ATTEMPT)

    def retained_fixture(self):
        result = passed_result()
        retained = self.evidence / "retained"
        retained.mkdir()
        archive = b"synthetic archive bytes; not a compiled app"
        receipt_hash = "3" * 64
        manifest = {
            "source": {"commitSHA": exporter.SOURCE_COMMIT, "treeSHA": exporter.SOURCE_TREE},
            "ci": {"runID": RUN, "runAttempt": ATTEMPT},
            "limits": {"validationMode": "unsigned-ci-package-validation-only", "codeSigningPerformed": False, "releaseBuildProvenanceCreated": False, "distributionEligible": False, "compilerAttestation": False, "nativeAdmission": False},
            "app": {"bundleIdentifier": "org.imrse.app", "architecture": "arm64", "ciValidationReceiptSHA256": receipt_hash},
            "archive": {"file": exporter.ARCHIVE, "sha256": exporter.digest(archive), "sizeBytes": len(archive)},
        }
        payload = json.dumps(manifest).encode()
        checksums = f"{exporter.digest(archive)}  {exporter.ARCHIVE}\n{exporter.digest(payload)}  {exporter.MANIFEST}\n".encode()
        (retained / exporter.ARCHIVE).write_bytes(archive)
        (retained / exporter.MANIFEST).write_bytes(payload)
        (retained / "SHA256SUMS").write_bytes(checksums)
        result["product"] = {"receiptSHA256": receipt_hash}
        result["artifact"] = {"archive": manifest["archive"], "manifestSHA256": exporter.digest(payload), "checksumsSHA256": exporter.digest(checksums)}
        self.write_result(result)
        return result

    def test_projection_preserves_evidence_and_omits_unapproved_text(self):
        secret = "synthetic-sensitive-sentinel"
        result = passed_result()
        result["failure"] = "ScopeError:build-not-ok:" + secret
        result["phases"][0]["argv"] = [secret]
        result["phases"][0]["primaryFailure"] = {"sha256": secret}
        result["run"]["RUNNER_NAME"] = secret
        result["unknown"] = secret
        result["toolchain"] = {"osVersion": "27.0.1", "sdkVersion": "27.1", "xcode": "Xcode 27.1\nBuild version 18A1", "swift": "Apple Swift version 6.4.0 " + secret, "metalExitCode": 0, "buildHelp": secret, "developerDirectory": secret}
        projected = exporter.public_receipt(result, CONTROL, RUN, ATTEMPT)
        text = json.dumps(projected)
        self.assertNotIn(secret, text)
        self.assertNotIn("argv", text)
        self.assertNotIn("RUNNER_NAME", text)
        self.assertEqual(projected["failure"]["categories"], ["ScopeError", "build-not-ok"])
        self.assertTrue(projected["phases"][0]["closure"]["complete"])
        self.assertEqual(projected["phases"][0]["firstResource"]["filesystemAvailableBytes"], 20 * 1024**3)
        self.assertEqual(projected["toolchain"]["swift"], "6.4.0")
        self.assertFalse(projected["delivery"]["compilerAttestation"])

    def test_success_exports_only_exact_retained_files_and_receipts(self):
        self.retained_fixture()
        self.assertEqual(self.run_export(), 0)
        receipt = self.read_receipt()
        self.assertTrue(receipt["delivery"]["appIncluded"])
        self.assertEqual(receipt["delivery"]["retentionDays"], 7)
        self.assertEqual({path.relative_to(self.output).as_posix() for path in self.output.rglob("*") if path.is_file()}, {"receipts/hosted-combined-receipt.json", "receipts/build-summary.txt", "app/" + exporter.ARCHIVE, "app/" + exporter.MANIFEST, "app/SHA256SUMS"})
        self.assertEqual((self.output / "app" / exporter.ARCHIVE).read_bytes(), (self.evidence / "retained" / exporter.ARCHIVE).read_bytes())

    def test_failure_and_cancellation_export_receipts_without_reading_retention(self):
        for status in ("failed", "cancelled"):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as directory:
                self.output = Path(directory).resolve() / "public"
                result = passed_result()
                result["status"] = status
                result["failure"] = "synthetic-sensitive-sentinel"
                self.write_result(result)
                with patch.object(exporter, "export_app", side_effect=AssertionError("must not read retention")):
                    self.assertEqual(self.run_export(), 0)
                self.assertEqual(self.read_receipt()["status"], status)
                self.assertFalse(self.read_receipt()["delivery"]["appIncluded"])
                self.assertFalse((self.output / "app").exists())

    def test_missing_result_exports_incomplete_receipt_and_fails(self):
        self.assertEqual(self.run_export(), 1)
        receipt = self.read_receipt()
        self.assertEqual(receipt["status"], "unavailable")
        self.assertEqual(receipt["delivery"]["exportStatus"], "failed")
        self.assertFalse(receipt["delivery"]["appIncluded"])

    def test_identity_and_incomplete_phase_never_export_app(self):
        mutations = [
            lambda result: result.update(sourceCommit="0" * 40),
            lambda result: result["control"].update(clean=False),
            lambda result: result["run"].update(GITHUB_RUN_ATTEMPT="2"),
            lambda result: result["admissions"].pop(),
            lambda result: result["admissions"][0].update(issues=["low-space"]),
            lambda result: result["admissions"][0].update(requiredFloorBytes=0),
            lambda result: result["phases"].pop(),
            lambda result: result["phases"][0].update(exitCode=False),
            lambda result: result["phases"][0].pop("primaryFailure"),
            lambda result: result["phases"][0].update(outputTruncated=True),
            lambda result: result["phases"][0].update(resourceViolations=["low-space"]),
            lambda result: result["phases"][0].update(groupEscapes=[[101, "fixture"]]),
            lambda result: result["phases"][0]["closure"].update(complete=False),
            lambda result: result["phases"][0]["closure"].update(rootReaped=False),
            lambda result: result["phases"][0]["closure"].update(signalAuthorityRetired=False),
            lambda result: result["phases"][0]["closure"].update(remaining=[[101, "fixture"]]),
            lambda result: result["phases"][0]["closure"].pop("escapes"),
        ]
        for mutate in mutations:
            result = passed_result()
            mutate(result)
            with self.subTest(result=result), self.assertRaises(exporter.DeliveryError):
                exporter.validate_success(result, CONTROL, RUN, ATTEMPT)

    def test_corrupt_archive_preserves_observed_receipts_but_fails_delivery(self):
        self.retained_fixture()
        archive = self.evidence / "retained" / exporter.ARCHIVE
        archive.write_bytes(b"X" * archive.stat().st_size)
        self.assertEqual(self.run_export(), 1)
        receipt = self.read_receipt()
        self.assertEqual(receipt["status"], "passed")
        self.assertEqual(len(receipt["phases"]), 3)
        self.assertEqual(receipt["delivery"]["exportStatus"], "failed")
        self.assertFalse(receipt["delivery"]["appIncluded"])
        self.assertFalse((self.output / "app" / exporter.ARCHIVE).exists())

    def test_manifest_or_checksums_tampering_refuses_delivery(self):
        self.retained_fixture()
        (self.evidence / "retained/SHA256SUMS").write_bytes(b"unexpected")
        self.assertEqual(self.run_export(), 1)
        self.assertFalse((self.output / "app").exists())

    def test_archive_name_cannot_escape_retained_directory(self):
        result = self.retained_fixture()
        result["artifact"]["archive"]["file"] = "../unapproved"
        self.write_result(result)
        self.assertEqual(self.run_export(), 1)
        self.assertFalse((self.output / "app").exists())

    def test_linked_result_is_refused_before_open(self):
        target = self.root / "unapproved"
        target.write_text("synthetic-sensitive-sentinel")
        (self.evidence / "hosted-combined-result.json").symlink_to(target)
        self.assertEqual(self.run_export(), 1)
        self.assertNotIn("synthetic-sensitive-sentinel", json.dumps(self.read_receipt()))

    def test_oversize_result_is_refused_before_read(self):
        self.write_result(passed_result())
        with patch.object(exporter, "MAX_RESULT_BYTES", 10):
            self.assertEqual(self.run_export(), 1)
        self.assertEqual(self.read_receipt()["status"], "unavailable")

    def test_nonfinite_numbers_and_unbounded_depth_are_refused(self):
        for value in (float("nan"), float("inf")):
            with self.assertRaises(exporter.DeliveryError):
                exporter.project(value)
        value = None
        for _ in range(14):
            value = {"closure": value}
        with self.assertRaises(exporter.DeliveryError):
            exporter.project(value)

    def test_existing_output_is_not_overwritten(self):
        self.output.mkdir()
        sentinel = self.output / "sentinel"
        sentinel.write_text("keep")
        with self.assertRaises(FileExistsError):
            self.run_export()
        self.assertEqual(sentinel.read_text(), "keep")

    def test_workflow_uses_exact_files_pins_retention_and_success_gate(self):
        workflow = Path(__file__).resolve().parents[2] / "workflows/verify.yml"
        job = workflow.read_text().split("  hosted-combined-build:", 1)[1]
        self.assertEqual(job.count("actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02"), 2)
        self.assertEqual(job.count("retention-days: 7"), 2)
        self.assertEqual(job.count("include-hidden-files: false"), 2)
        self.assertIn("success() && steps.build.outcome == 'success' && steps.export.outcome == 'success'", job)
        upload_paths = job.split("path: |")
        self.assertEqual(len(upload_paths), 3)
        self.assertNotIn("*", "".join(upload_paths[1:]))
        self.assertNotIn("/logs/", job)
        self.assertNotIn("/retained/", job)


if __name__ == "__main__":
    unittest.main()
