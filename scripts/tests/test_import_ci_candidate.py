import hashlib
import importlib.util
import io
import json
import stat
import sys
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location(
    "import_ci_candidate", ROOT / "scripts/import-ci-candidate.py"
)
importer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(importer)
COMMIT, TREE = importer.git_id(ROOT)
EVENT = "c" * 40
EXTENSIONS = importer.approved_extensions(ROOT, COMMIT)
LICENSE = b"synthetic upstream swift-argument-parser license\n"
APPROVED_PATCH = {
    "schemaVersion": 1,
    "identity": "swift-argument-parser",
    "version": "1.8.2",
    "url": "https://github.com/apple/swift-argument-parser",
    "revision": "6a52f3251125d74daf04fcbd5e6f08a75d074382",
    "license": {"path": "LICENSE.txt", "sha256": hashlib.sha256(LICENSE).hexdigest()},
    "files": [
        {"path": "Sources/ArgumentParser/Parsable Types/ParsableArguments.swift",
         "originalSHA256": "a" * 64, "patchedSHA256": "b" * 64, "originalSize": 120,
         "patchedSize": 80, "removedAnnotation": '@available(*, deprecated, message: "Use _errorPrefix instead.")'},
        {"path": "Sources/ArgumentParserToolInfo/ToolInfo.swift",
         "originalSHA256": "c" * 64, "patchedSHA256": "d" * 64, "originalSize": 121,
         "patchedSize": 81, "removedAnnotation": '@available(*, deprecated, message: "Use custom instead.")'},
    ],
}
PATCH_RAW = (json.dumps(APPROVED_PATCH, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def make(
    base,
    bad=None,
    receipt_bad=False,
    attack=None,
    extra=(),
    extension_bad=False,
    extension_missing=False,
    patch_bad=None,
):
    root = base / "source"
    root.mkdir()
    (root / "Package.resolved").write_bytes(b"pins fixture\n")
    app = base / "imrse.app"
    executable = app / "Contents/MacOS/imrse"
    executable.parent.mkdir(parents=True)
    executable.write_bytes(b"synthetic executable")
    executable.chmod(0o755)

    resources = app / "Contents/Resources"
    resources.mkdir(parents=True)
    patch_raw = PATCH_RAW
    if patch_bad == "embedded":
        patch_raw = b"tampered embedded proof\n"
    if patch_bad == "noncanonical":
        patch_raw = (json.dumps(APPROVED_PATCH, sort_keys=True, indent=2) + "\n").encode()
    if patch_bad in {"revision", "expanded"}:
        changed = json.loads(PATCH_RAW)
        changed["revision" if patch_bad == "revision" else "unexpectedScope"] = (
            "0" * 40 if patch_bad == "revision" else True
        )
        patch_raw = (json.dumps(changed, sort_keys=True, separators=(",", ":")) + "\n").encode()
    if patch_bad == "missing-embedded":
        patch_raw = None
    if patch_raw is not None:
        (resources / "ThirdPartyLicenses/swift-argument-parser-COMPATIBILITY.json").parent.mkdir(parents=True)
        (resources / "ThirdPartyLicenses/swift-argument-parser-COMPATIBILITY.json").write_bytes(patch_raw)
    app_license = resources / "ThirdPartyLicenses/swift-argument-parser-LICENSE.txt"
    app_license.parent.mkdir(parents=True, exist_ok=True)
    app_license.write_bytes(
        b"tampered app license\n" if patch_bad == "app-license" else LICENSE
    )
    (resources / "data").write_bytes(b"synthetic resource")
    readonly = resources / "readonly"
    readonly.write_bytes(b"read-only resource")
    readonly.chmod(0o444)
    if attack == "symlink":
        (resources / "evil").symlink_to("../../../../escape")

    receipt = {
        "schemaVersion": 1,
        "validationMode": "unsigned-ci-package-validation-only",
        "distributionEligible": False,
        "codeSigningPerformed": False,
        "signingCertificateSHA1": None,
        "signatureReceipt": None,
        "releaseBuildProvenanceCreated": False,
        "source": {"commitSHA": COMMIT, "treeSHA": TREE},
        "product": {
            "bundleIdentifier": "org.imrse.app",
            "hostArchitecture": "arm64",
            "machoArchitectures": {"Contents/MacOS/imrse": "arm64"},
            "executableSHA256": sha256(executable.read_bytes()),
        },
    }
    if receipt_bad:
        receipt["distributionEligible"] = True
    (resources / importer.R).write_text(json.dumps(receipt, sort_keys=True) + "\n")
    resources.chmod(0o750)

    entries = importer.pkg.bundle_tree_entries(app)
    tree_hash = sha256(json.dumps(entries, sort_keys=True, separators=(",", ":")).encode())
    tar_path = base / importer.A
    with tarfile.open(tar_path, "w:gz") as archive:
        if attack == "hardlink":
            archive.add(app, arcname="imrse.app", recursive=False)
            for item in sorted(app.rglob("*")):
                name = "imrse.app/" + item.relative_to(app).as_posix()
                if name.endswith("/Resources/data"):
                    member = tarfile.TarInfo(name)
                    member.type = tarfile.LNKTYPE
                    member.mode = stat.S_IMODE(item.lstat().st_mode)
                    member.linkname = "imrse.app/Contents/MacOS/imrse"
                    archive.addfile(member)
                else:
                    archive.add(item, arcname=name, recursive=False)
        else:
            archive.add(app, arcname="imrse.app")
            if attack == "traversal":
                member = tarfile.TarInfo("../escape")
                member.size = 1
                archive.addfile(member, io.BytesIO(b"x"))

    files = {
        "build.log": b"build",
        "eventsource-tests.log": b"tests",
        "root-effective-dependency-graph.json": b"{}",
        importer.PT: b"ArgumentParser compatibility checks passed.\n",
        importer.PD: b"{}\n",
        importer.BI: b'{"checkedCompilerInputs": []}\n',
    }
    extension_receipt = json.loads(json.dumps(EXTENSIONS))
    if extension_bad == "revision":
        extension_receipt["packages"][0]["revision"] = "0" * 40
    elif extension_bad == "source-hash":
        extension_receipt["packages"][0]["sourceSHA256"]["Plugins/CudaBuild/plugin.swift"] = (
            "0" * 64
        )
    elif extension_bad == "schema-version":
        extension_receipt["schemaVersion"] = True
    if not extension_missing:
        files["extension-enablement.json"] = json.dumps(
            extension_receipt, sort_keys=True
        ).encode()

    manifest = {
        "schemaVersion": 1,
        "source": {
            "commitSHA": COMMIT,
            "treeSHA": TREE,
            "selectedCommitSHA": COMMIT,
            "eventSHA": EVENT,
        },
        "ci": {
            "workflow": "verify",
            "job": "package",
            "runID": "1234",
            "runAttempt": "2",
            "eventName": "push",
        },
        "host": {"os": "macOS", "architecture": "arm64"},
        "build": {
            "buildLogSHA256": sha256(files["build.log"]),
            "eventsourceTestLogSHA256": sha256(files["eventsource-tests.log"]),
        },
        "dependencies": {
            "rootGraphSHA256": sha256(files["root-effective-dependency-graph.json"]),
            "packageResolvedSHA256": sha256((root / "Package.resolved").read_bytes()),
            "argumentParserPatchReceiptSHA256": sha256(patch_raw or PATCH_RAW),
            "argumentParserCompatibilityTestLogSHA256": sha256(files[importer.PT]),
            "argumentParserDumpHelpSHA256": sha256(files[importer.PD]),
            "argumentParserBuildInputsSHA256": sha256(files[importer.BI]),
        },
        "app": {"bundleTreeSHA256": tree_hash, "inventory": entries},
        "archive": {
            "file": importer.A,
            "sha256": sha256(tar_path.read_bytes()),
            "format": "tar.gz; Unix modes preserved",
        },
    }
    if bad:
        bad(manifest)

    raw = (json.dumps(manifest, sort_keys=True) + "\n").encode()
    artifact = base / "artifact.zip"
    with zipfile.ZipFile(artifact, "w", zipfile.ZIP_STORED) as archive:
        archive.writestr(importer.A, tar_path.read_bytes())
        archive.writestr(importer.M, raw)
        if patch_bad != "missing-sidecar":
            archive.writestr(importer.P, patch_raw or PATCH_RAW)
        for name, value in files.items():
            archive.writestr(name, value)
        for item in extra:
            archive.writestr(*item)
    return artifact, root


def run(base, **args):
    artifact, root = make(base, **args)
    with patch.object(importer, "git_id", return_value=(COMMIT, TREE)):
        with patch.object(importer, "approved_extensions", return_value=EXTENSIONS):
            with patch.object(importer, "approved_patch", return_value=APPROVED_PATCH):
                return importer.import_candidate(
                    artifact,
                    sha256(artifact.read_bytes()),
                    root,
                    COMMIT,
                    TREE,
                    "1234",
                    "2",
                    base / "out",
                )


def reject(test, base, expected=None, **args):
    artifact, root = make(base, **args)
    with patch.object(importer, "git_id", return_value=(COMMIT, TREE)):
        with patch.object(importer, "approved_extensions", return_value=EXTENSIONS):
            with patch.object(importer, "approved_patch", return_value=APPROVED_PATCH):
                with test.assertRaises((importer.CandidateError, KeyError)):
                    importer.import_candidate(
                        artifact,
                        expected or sha256(artifact.read_bytes()),
                        root,
                        COMMIT,
                        TREE,
                        "1234",
                        "2",
                        base / "out",
                    )
    test.assertFalse((base / "out").exists())


class ImportTests(unittest.TestCase):
    def test_positive_preserves_modes_receipt_and_two_evidence_records(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            output = run(base, extra=(("public-sidecar.json", b"fixture"),))
            original = (base / "imrse.app/Contents/Resources" / importer.R).read_bytes()
            imported = output / "imrse.app/Contents/Resources" / importer.R
            self.assertEqual(imported.read_bytes(), original)
            self.assertEqual(stat.S_IMODE((output / "imrse.app/Contents/MacOS/imrse").stat().st_mode), 0o755)
            resources = output / "imrse.app/Contents/Resources"
            self.assertEqual(stat.S_IMODE(resources.stat().st_mode), 0o750)
            self.assertEqual(stat.S_IMODE((resources / "readonly").stat().st_mode), 0o444)
            self.assertTrue((output / "candidate-import-receipt.json").is_file())
            evidence = json.loads((output / "candidate-import-receipt.json").read_text())
            self.assertEqual(set(evidence["source"]), {"commitSHA", "treeSHA"})
            self.assertEqual(len(evidence["checksums"]), 2)
            self.assertIn("no signing", evidence["scope"])
            self.assertEqual((output / importer.P).read_bytes(), PATCH_RAW)
            provenance = json.loads((output / importer.M).read_text())
            self.assertEqual(provenance["dependencies"]["argumentParserPatchReceiptSHA256"], sha256(PATCH_RAW))

    def test_bad_outer_inner_identity_log_receipt_inventory_and_lock_hashes(self):
        def bad_inventory(manifest):
            executable = next(
                entry
                for entry in manifest["app"]["inventory"]
                if entry["path"] == "Contents/MacOS/imrse"
            )
            executable["sha256"] = "0" * 64
            manifest["app"]["bundleTreeSHA256"] = sha256(
                json.dumps(
                    manifest["app"]["inventory"],
                    sort_keys=True,
                    separators=(",", ":"),
                ).encode()
            )

        cases = (
            ({}, "outer", {"expected": "0" * 64}),
            ({"bad": lambda data: data["archive"].update(sha256="0" * 64)}, "inner", {}),
            ({"bad": lambda data: data["ci"].update(runID="9")}, "identity", {}),
            ({"bad": lambda data: data["build"].update(buildLogSHA256="0" * 64)}, "log", {}),
            ({}, "receipt", {"receipt_bad": True}),
            ({"bad": bad_inventory}, "inventory", {}),
            ({}, "extension revision tampering", {"extension_bad": "revision"}),
            ({}, "extension hash tampering", {"extension_bad": "source-hash"}),
            ({}, "extension schema version type", {"extension_bad": "schema-version"}),
            ({}, "missing extension receipt", {"extension_missing": True}),
            ({}, "missing compatibility sidecar", {"patch_bad": "missing-sidecar"}),
            ({}, "wrong compatibility revision", {"patch_bad": "revision"}),
            ({}, "expanded compatibility scope", {"patch_bad": "expanded"}),
            ({}, "noncanonical compatibility receipt", {"patch_bad": "noncanonical"}),
            ({}, "tampered embedded compatibility receipt", {"patch_bad": "embedded"}),
            ({}, "missing embedded compatibility receipt", {"patch_bad": "missing-embedded"}),
            ({}, "tampered app license", {"patch_bad": "app-license"}),
            ({"bad": lambda data: data["dependencies"].update(argumentParserPatchReceiptSHA256="0" * 64)},
             "compatibility receipt digest", {}),
        )
        for args, label, extra in cases:
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temp:
                reject(self, Path(temp), **args, **extra)

        for key in ("argumentParserCompatibilityTestLogSHA256", "argumentParserDumpHelpSHA256",
                    "argumentParserBuildInputsSHA256"):
            with self.subTest(dependency=key), tempfile.TemporaryDirectory() as temp:
                reject(self, Path(temp), bad=lambda data, key=key: data["dependencies"].update({key: "0" * 64}))

        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            artifact, root = make(base)
            (root / "Package.resolved").write_text("changed\n")
            with patch.object(importer, "git_id", return_value=(COMMIT, TREE)):
                with patch.object(importer, "approved_extensions", return_value=EXTENSIONS):
                    with patch.object(importer, "approved_patch", return_value=APPROVED_PATCH):
                        with self.assertRaises(importer.CandidateError):
                            importer.import_candidate(
                                artifact,
                                sha256(artifact.read_bytes()),
                                root,
                                COMMIT,
                                TREE,
                                "1234",
                                "2",
                                base / "out",
                            )

    def test_unsafe_tar_paths_links_and_hardlinks(self):
        for attack in ("traversal", "symlink", "hardlink"):
            with self.subTest(attack=attack), tempfile.TemporaryDirectory() as temp:
                reject(self, Path(temp), attack=attack)

    def test_unsafe_and_duplicate_zip_entries(self):
        cases = [(name, b"x") for name in ("../escape", "/absolute", "folder\\escape")]
        for mode in (stat.S_IFLNK | 0o777, stat.S_IFIFO | 0o600):
            item = zipfile.ZipInfo("extra")
            item.create_system, item.external_attr = 3, mode << 16
            cases.append((item, b"x"))
        cases.append(("build.log", b"duplicate"))
        for entry in cases:
            with self.subTest(entry=str(entry[0])), tempfile.TemporaryDirectory() as temp:
                reject(self, Path(temp), extra=(entry,))

    def test_approved_patch_uses_expected_git_blob_literal_without_execution(self):
        committed = f"APPROVED_PATCH = {APPROVED_PATCH!r}\nraise RuntimeError('must not run')\n"
        with patch.object(importer.subprocess, "check_output", return_value=committed) as show:
            self.assertEqual(importer.approved_patch(Path("/source"), COMMIT), APPROVED_PATCH)
        self.assertEqual(show.call_args.args[0][-1], f"{COMMIT}:{importer.ci_approval.PATCH_HELPER}")


if __name__ == "__main__":
    unittest.main()
