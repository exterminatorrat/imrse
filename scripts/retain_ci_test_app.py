#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import re
import stat
import sys
import tarfile
from pathlib import Path, PurePosixPath

if __package__:
    from . import package_local_candidate as package
else:
    import package_local_candidate as package


MAX_ENTRIES = 256
MAX_APP_BYTES = 128 * 1024 * 1024
MAX_RECEIPT_BYTES = 64 * 1024
RECEIPT_PATH = "Contents/Resources/CI-PACKAGE-VALIDATION.json"
ARCHIVE_NAME = "imrse-ci-test-app-arm64.tar.gz"
MANIFEST_NAME = "ci-test-app-manifest.json"
CHECKSUMS_NAME = "SHA256SUMS"


class RetentionError(Exception):
    pass


def _fail(condition, message):
    if not condition:
        raise RetentionError(message)


def _source(root, expected_commit):
    _fail(re.fullmatch(r"[0-9a-f]{40}", expected_commit) is not None, "expected commit must be a full lowercase Git object id")
    commit = package.run(["git", "rev-parse", "HEAD^{commit}"], cwd=root).strip()
    _fail(commit == expected_commit, "checkout differs from the expected source commit")
    tree = package.run(["git", "rev-parse", "HEAD^{tree}"], cwd=root).strip()
    try:
        root = package.validate_source_checkout(root, commit, tree)
    except package.PackageError as error:
        raise RetentionError(str(error)) from error
    return root, commit, tree


def _inventory(bundle):
    count = 1
    total_bytes = 0
    pending = [bundle]
    while pending:
        directory = pending.pop()
        with os.scandir(directory) as children:
            for child in children:
                count += 1
                _fail(count <= MAX_ENTRIES, "app bundle exceeds the retained inventory limit")
                info = child.stat(follow_symlinks=False)
                if stat.S_ISDIR(info.st_mode):
                    pending.append(Path(child.path))
                elif stat.S_ISREG(info.st_mode):
                    _fail(info.st_nlink == 1, "hard-linked app files are not supported")
                    relative = Path(child.path).relative_to(bundle).as_posix()
                    _fail(relative != RECEIPT_PATH or info.st_size <= MAX_RECEIPT_BYTES, "CI validation receipt exceeds its size limit")
                    total_bytes += info.st_size
                    _fail(total_bytes <= MAX_APP_BYTES, "app bundle exceeds the retained size limit")
                else:
                    raise RetentionError("app bundle contains a link or unsupported file type")
    entries = package.bundle_tree_entries(bundle)
    _fail(len(entries) == count, "app bundle changed while inventory was collected")
    _fail(all(entry["type"] in {"directory", "file"} for entry in entries), "app bundle contains a link or unsupported file type")
    entries.sort(key=lambda entry: entry["path"])
    _fail(
        all(
            entry["path"] == "."
            or (not PurePosixPath(entry["path"]).is_absolute() and "\\" not in entry["path"] and not any(part in {"", ".", ".."} for part in PurePosixPath(entry["path"]).parts))
            for entry in entries
        ),
        "app bundle contains an unsafe archive path",
    )
    measured_bytes = sum(entry.get("size", 0) for entry in entries)
    _fail(measured_bytes == total_bytes, "app bundle changed while inventory was collected")
    return entries, total_bytes


def _validate_receipt(bundle, entries, commit, tree):
    receipt_entry = next((entry for entry in entries if entry["path"] == RECEIPT_PATH), None)
    _fail(receipt_entry is not None and receipt_entry["type"] == "file", "CI validation receipt is missing from the app")
    _fail(receipt_entry["size"] <= MAX_RECEIPT_BYTES, "CI validation receipt exceeds its size limit")
    receipt_path = bundle / RECEIPT_PATH
    try:
        receipt = package.strict_json_loads(receipt_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise RetentionError("CI validation receipt is not valid strict JSON") from error
    _fail(isinstance(receipt, dict), "CI validation receipt has an invalid shape")
    _fail(receipt.get("schemaVersion") == 1, "unsupported CI validation receipt schema")
    _fail(receipt.get("validationMode") == "unsigned-ci-package-validation-only", "app is not marked for unsigned CI validation")
    _fail(receipt.get("distributionEligible") is False, "CI validation app is marked distribution eligible")
    _fail(receipt.get("codeSigningPerformed") is False, "CI validation app claims code signing")
    _fail(receipt.get("signingCertificateSHA1") is None, "CI validation app claims a signing certificate")
    _fail(receipt.get("signatureReceipt") is None, "CI validation app contains a signature receipt")
    _fail(receipt.get("releaseBuildProvenanceCreated") is False, "CI validation app claims Release provenance")
    _fail(receipt.get("source") == {"commitSHA": commit, "treeSHA": tree}, "CI validation receipt names different source")
    checks = receipt.get("checks")
    _fail(isinstance(checks, dict) and checks.get("cleanCommittedSourceAndVersionMatch") == "passed", "CI receipt does not record a clean source check")
    product = receipt.get("product")
    _fail(isinstance(product, dict), "CI validation receipt has no product record")
    _fail(product.get("bundleIdentifier") == package.EXPECTED_BUNDLE_ID, "CI validation receipt names a different app identity")
    _fail(product.get("hostArchitecture") == "arm64", "CI validation receipt is not from an arm64 host")
    architectures = product.get("machoArchitectures")
    _fail(
        isinstance(architectures, dict)
        and architectures.get("Contents/MacOS/imrse") == "arm64"
        and all(architecture == "arm64" for architecture in architectures.values()),
        "CI validation receipt is not arm64-only",
    )
    files = {entry["path"]: entry for entry in entries if entry["type"] == "file"}
    executable = files.get("Contents/MacOS/imrse")
    info_plist = files.get("Contents/Info.plist")
    _fail(executable is not None and info_plist is not None, "app bundle is missing executable or Info.plist inventory")
    _fail(executable["mode"] & 0o111 != 0, "app executable is not marked executable")
    _fail(product.get("executableSHA256") == executable["sha256"], "CI receipt executable hash differs from the app")
    _fail(product.get("infoPlistSHA256") == info_plist["sha256"], "CI receipt Info.plist hash differs from the app")
    return receipt_entry["sha256"]


def retain_ci_test_app(source_root, app, output_dir, expected_commit, run_id, run_attempt):
    _fail(re.fullmatch(r"[1-9][0-9]*", run_id) is not None, "CI run id must be a positive integer")
    _fail(re.fullmatch(r"[1-9][0-9]*", run_attempt) is not None, "CI run attempt must be a positive integer")
    root, commit, tree = _source(Path(source_root).expanduser(), expected_commit)
    raw_app = Path(app).expanduser()
    _fail(raw_app.is_absolute() and not raw_app.is_symlink(), "app path must be an absolute, non-symlink path")
    try:
        bundle = raw_app.resolve(strict=True)
    except OSError as error:
        raise RetentionError("CI app bundle does not exist") from error
    _fail(bundle.is_dir() and bundle.name == "imrse.app", "app path must name an imrse.app bundle")
    _fail(
        bundle != root and not bundle.is_relative_to(root) and not root.is_relative_to(bundle),
        "CI app bundle must be separate from the source checkout",
    )
    output = Path(output_dir).expanduser()
    _fail(output.is_absolute() and not os.path.lexists(output), "output directory must be a new absolute path")
    try:
        output_parent = output.parent.resolve(strict=True)
    except OSError as error:
        raise RetentionError("output directory parent must already exist") from error
    _fail(output_parent.is_dir(), "output directory parent must be a directory")
    output = output_parent / output.name
    _fail(
        output != root and not output.is_relative_to(root) and not root.is_relative_to(output),
        "output directory must be separate from the source checkout",
    )
    _fail(output != bundle and not output.is_relative_to(bundle) and not bundle.is_relative_to(output), "output directory must be separate from the CI app")
    try:
        entries, total_bytes = _inventory(bundle)
        source_info = package.read_source_info(root)
        _, app_info = package.validate_built_app_bundle(bundle, source_info)
    except package.PackageError as error:
        raise RetentionError(str(error)) from error
    receipt_sha256 = _validate_receipt(bundle, entries, commit, tree)
    output.mkdir(mode=0o700)
    archive_path = output / ARCHIVE_NAME
    try:
        with tarfile.open(archive_path, "x:gz", format=tarfile.PAX_FORMAT) as archive:
            for entry in entries:
                relative = entry["path"]
                source = bundle if relative == "." else bundle.joinpath(*PurePosixPath(relative).parts)
                current = source.lstat()
                if entry["type"] == "directory":
                    _fail(stat.S_ISDIR(current.st_mode), "app bundle changed during archive creation")
                else:
                    _fail(stat.S_ISREG(current.st_mode) and current.st_nlink == 1, "app bundle changed during archive creation")
                    _fail(current.st_size == entry["size"], "app bundle changed during archive creation")
                _fail(stat.S_IMODE(current.st_mode) == entry["mode"], "app mode changed during archive creation")
                arcname = "imrse.app" if relative == "." else f"imrse.app/{relative}"
                archive.add(source, arcname=arcname, recursive=False)
        final_entries, final_bytes = _inventory(bundle)
        _fail(final_entries == entries and final_bytes == total_bytes, "app bundle changed during archive creation")
        with tarfile.open(archive_path, "r:gz") as archive:
            members = archive.getmembers()
            _fail(len(members) == len(entries), "archive inventory differs from the app")
            for member, entry in zip(members, entries):
                name = "imrse.app" if entry["path"] == "." else f"imrse.app/{entry['path']}"
                _fail(member.name == name and member.mode == entry["mode"], "archive path or mode differs from the app")
                if entry["type"] == "directory":
                    _fail(member.isdir(), "archive entry type differs from the app")
                    continue
                _fail(member.isfile() and member.size == entry["size"], "archive file differs from the app")
                digest = hashlib.sha256()
                with archive.extractfile(member) as source:
                    for chunk in iter(lambda: source.read(65536), b""):
                        digest.update(chunk)
                _fail(digest.hexdigest() == entry["sha256"], "archived bytes differ from the app")
    except (OSError, tarfile.TarError) as error:
        raise RetentionError("could not create the bounded app archive") from error
    archive_sha256 = package.sha256_file(archive_path)
    manifest = {
        "schemaVersion": 1,
        "scope": "unsigned CI validation app for private local testing only",
        "limits": {
            "validationMode": "unsigned-ci-package-validation-only",
            "codeSigningPerformed": False,
            "releaseBuildProvenanceCreated": False,
            "distributionEligible": False,
            "compilerAttestation": False,
            "nativeAdmission": False,
            "maxInventoryEntries": MAX_ENTRIES,
            "maxAppBytes": MAX_APP_BYTES,
        },
        "source": {"commitSHA": commit, "treeSHA": tree},
        "ci": {"runID": run_id, "runAttempt": run_attempt},
        "app": {
            "path": "imrse.app",
            "bundleIdentifier": app_info["CFBundleIdentifier"],
            "architecture": "arm64",
            "totalBytes": total_bytes,
            "ciValidationReceiptSHA256": receipt_sha256,
            "inventory": entries,
        },
        "archive": {
            "file": ARCHIVE_NAME,
            "format": "tar.gz; PAX; Unix modes preserved",
            "sizeBytes": archive_path.stat().st_size,
            "sha256": archive_sha256,
        },
    }
    manifest_path = output / MANIFEST_NAME
    with manifest_path.open("x", encoding="utf-8") as destination:
        destination.write(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    manifest_sha256 = package.sha256_file(manifest_path)
    checksums_path = output / CHECKSUMS_NAME
    with checksums_path.open("x", encoding="utf-8") as destination:
        destination.write(f"{archive_sha256}  {ARCHIVE_NAME}\n{manifest_sha256}  {MANIFEST_NAME}\n")
    return output


def main(argv=None):
    parser = argparse.ArgumentParser(description="Retain a bounded unsigned CI app for private testing")
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--expected-commit", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--run-attempt", required=True)
    args = parser.parse_args(argv)
    try:
        output = retain_ci_test_app(args.source_root, args.app, args.output_dir, args.expected_commit, args.run_id, args.run_attempt)
    except (RetentionError, package.PackageError, OSError, ValueError, tarfile.TarError) as error:
        print(f"CI app retention failed: {error}", file=sys.stderr)
        return 1
    print(f"Retained unsigned CI app: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
