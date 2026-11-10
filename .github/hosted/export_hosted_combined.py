#!/usr/bin/env python3
import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import stat

SOURCE_COMMIT = "535b7f85720b2e53c60604e8b7c8abfb4e97ca4b"
SOURCE_TREE = "711a36772737488bb99ffd3a00cbce277be68a68"
ARCHIVE = "imrse-ci-test-app-arm64.tar.gz"
MANIFEST = "ci-test-app-manifest.json"
MAX_RESULT_BYTES = 16 * 1024**2
MAX_PUBLIC_BYTES = 2 * 1024**2
MAX_ARCHIVE_BYTES = 129 * 1024**2
PACKAGES = set("eventsource lottie-ios mlx-swift mlx-swift-lm swift-argument-parser swift-asn1 swift-collections swift-crypto swift-huggingface swift-jinja swift-numerics swift-syntax swift-transformers yyjson".split())
SOURCE_FILES = set("Package.swift Package.resolved pill-kit/native/Package.swift pill-kit/native/Package.resolved scripts/build-app.sh scripts/package_local_candidate.py scripts/retain_ci_test_app.py Resources/GenerateIcon.swift Resources/Info.plist LICENSE Resources/THIRD_PARTY_NOTICES.md pill-kit/THIRD_PARTY_NOTICES.md pill-kit/upstream/LICENSE Vendor/EventSource/LICENSE.md Vendor/EventSource/PROVENANCE.md Sources/ImrseApp/Resources/Brand/imrse-menubar-template.pdf Sources/ImrseLocal/Resources/Qwen3-APACHE-LICENSE.txt".split())
HASH_FIELDS = SOURCE_FILES | set("sourceCommit sourceTree controlCommit commitSHA treeSHA workflowSHA256 helperSHA256 exporterSHA256 receiptSHA256 executableSHA256 manifestSHA256 checksumsSHA256 ciValidationReceiptSHA256 sha256 revision".split())
FIELDS = HASH_FIELDS | PACKAGES | set("schemaVersion route status source control files clean dependencies pins checkouts missingCheckouts nested Source/Cmlx/mlx Source/Cmlx/mlx-c version phases admissions phase resources requiredFloorBytes issues complete filesystemAvailableBytes actualAPFSFreeBytes filesystemDevice containerReference memoryPressure swapUsedBytes reason name exitCode primaryFailure cleanupFailures resourceViolations closure observedOnly remaining groupMembers escapes rootReaped signalAuthorityRetired groupSignals outputBytes outputTruncated startedAt finishedAt rootIdentity resourceSamples firstResource lastResource groupEscapes reparented product artifact archive file sizeBytes bundleIdentifier architecture totalBytes inventoryEntries run GITHUB_RUN_ID GITHUB_RUN_ATTEMPT RUNNER_OS RUNNER_ARCH failure".split())
ENUMS = {
    "route": {"hosted-combined-535b7f8"},
    "status": {"passed", "failed", "cancelled", "running", "unavailable"},
    "name": {"resolve", "build", "retention"},
    "phase": {"pre-dependency", "pre-compiler", "post-build"},
    "file": {ARCHIVE},
    "bundleIdentifier": {"org.imrse.app"},
    "architecture": {"arm64"},
    "RUNNER_OS": {"macOS"},
    "RUNNER_ARCH": {"ARM64"},
    "missingCheckouts": PACKAGES,
}


class DeliveryError(Exception):
    pass


def digest(payload):
    return hashlib.sha256(payload).hexdigest()


def project(value, field="", depth=0):
    if depth > 12:
        raise DeliveryError("receipt-depth")
    if field in {"failure", "primaryFailure", "reason", "cleanupFailures", "resourceViolations", "issues"} and value is not None:
        if isinstance(value, list):
            if len(value) > 8192:
                raise DeliveryError("receipt-list")
            return [project(item, "reason", depth + 1) for item in value]
        text = value if isinstance(value, str) else json.dumps(value, sort_keys=True)
        codes = set("ScopeError ResourceError LifetimeError cancelled resolve-not-ok build-not-ok retention-not-ok pre-dependency pre-compiler post-build resource-command df diskutil-info diskutil-apfs sysctl-pressure sysctl-swap phase-exit phase-deadline runtime-deadline observation-gap closure-incomplete cleanup-failure output-join-timeout output-error process-table post-spawn-setup post-spawn-exception metadata-output-oversize deadline-exhausted resources-incomplete filesystem-free-below-floor apfs-free-below-floor memory-pressure swap-used".split())
        return {"textOmitted": True, "categories": [part.strip() for part in text.split(":") if part.strip() in codes][:8], "sha256": digest(text.encode())}
    if value is None or type(value) in (bool, int):
        return value
    if type(value) is float:
        if not math.isfinite(value):
            raise DeliveryError("receipt-number")
        return value
    if isinstance(value, dict):
        return {key: project(item, key, depth + 1) for key, item in value.items() if key in FIELDS}
    if isinstance(value, list):
        if len(value) > 8192:
            raise DeliveryError("receipt-list")
        return [project(item, field, depth + 1) for item in value]
    if not isinstance(value, str):
        raise DeliveryError("receipt-type")
    if field in HASH_FIELDS and re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", value):
        return value
    if value in ENUMS.get(field, set()):
        return value
    patterns = {
        "version": r"[0-9]+(?:\.[0-9]+){1,3}",
        "filesystemDevice": r"/dev/disk[0-9]+(?:s[0-9]+)*",
        "containerReference": r"disk[0-9]+",
        "memoryPressure": r"[0-9]+",
        "GITHUB_RUN_ID": r"[1-9][0-9]*",
        "GITHUB_RUN_ATTEMPT": r"[1-9][0-9]*",
    }
    if field in patterns and re.fullmatch(patterns[field], value):
        return value
    if field in {"rootIdentity", "remaining", "groupMembers", "escapes", "groupEscapes", "reparented"} and re.fullmatch(r"(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun) (?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+[0-9]{1,2} [0-9]{2}:[0-9]{2}:[0-9]{2} [0-9]{4}", value):
        return value
    return {"textOmitted": True, "sha256": digest(value.encode("utf-8"))}


def public_receipt(result, control_commit, run_id, attempt):
    receipt = project(result)
    toolchain = result.get("toolchain", {})
    versions = {}
    for field, pattern in {
        "osVersion": r"^([0-9]+(?:\.[0-9]+){1,3})$",
        "sdkVersion": r"^([0-9]+(?:\.[0-9]+){1,3})$",
        "xcode": r"^Xcode ([0-9]+(?:\.[0-9]+){0,3})(?:\n|$)",
        "swift": r"\bSwift version ([0-9]+(?:\.[0-9]+){1,3})\b",
    }.items():
        match = re.search(pattern, str(toolchain.get(field, "")))
        if match:
            versions[field] = match.group(1)
    versions["observationsSHA256"] = digest(json.dumps(toolchain, sort_keys=True).encode())
    versions["metalExitCode"] = toolchain.get("metalExitCode") if type(toolchain.get("metalExitCode")) is int else None
    receipt["toolchain"] = versions
    receipt["delivery"] = {
        "expectedControlCommit": control_commit,
        "runID": run_id,
        "runAttempt": attempt,
        "retentionDays": 7,
        "appIncluded": False,
        "distributionEligible": False,
        "compilerAttestation": False,
        "rawLogsIncluded": False,
        "textPolicy": "Only allowlisted fields and validated identity/version strings are published; other text is omitted and hashed.",
        "closureScope": "Bounded observed closure only; missing receipts or forcibly terminated export cannot establish closure.",
    }
    return receipt


def read_file(root, name, limit):
    path = root / name
    for parent in (root, *root.parents):
        if parent.is_symlink():
            raise DeliveryError("linked-root")
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > limit:
        raise DeliveryError("file-shape")
    with path.open("rb") as stream:
        payload = stream.read(limit + 1)
    if len(payload) != info.st_size or len(payload) > limit:
        raise DeliveryError("file-size")
    return payload


def validate_success(result, control_commit, run_id, attempt):
    if result.get("status") != "passed":
        return False
    if result.get("sourceCommit") != SOURCE_COMMIT or result.get("sourceTree") != SOURCE_TREE or result.get("controlCommit") != control_commit:
        raise DeliveryError("result-identity")
    source = result.get("source", {})
    control = result.get("control", {})
    if source.get("commitSHA") != SOURCE_COMMIT or source.get("treeSHA") != SOURCE_TREE or source.get("clean") is not True or control.get("commitSHA") != control_commit or control.get("clean") is not True:
        raise DeliveryError("checkout-identity")
    if result.get("run", {}).get("GITHUB_RUN_ID") != run_id or result.get("run", {}).get("GITHUB_RUN_ATTEMPT") != attempt:
        raise DeliveryError("run-identity")
    admissions = result.get("admissions", [])
    if [item.get("phase") for item in admissions] != ["pre-dependency", "pre-compiler", "post-build"]:
        raise DeliveryError("admission-set")
    for item, floor in zip(admissions, (16 * 1024**3, 16 * 1024**3, 12 * 1024**3)):
        if item.get("requiredFloorBytes") != floor or item.get("issues") != [] or item.get("resources", {}).get("complete") is not True:
            raise DeliveryError("admission-incomplete")
    phases = result.get("phases", [])
    if [phase.get("name") for phase in phases] != ["resolve", "build", "retention"]:
        raise DeliveryError("phase-set")
    for phase in phases:
        closure = phase.get("closure", {})
        if type(phase.get("exitCode")) is not int or phase["exitCode"] != 0 or "primaryFailure" not in phase or phase["primaryFailure"] is not None or phase.get("cleanupFailures") != [] or phase.get("resourceViolations") != [] or phase.get("outputTruncated") is not False or phase.get("groupEscapes") != []:
            raise DeliveryError("phase-incomplete")
        if closure.get("complete") is not True or closure.get("rootReaped") is not True or closure.get("signalAuthorityRetired") is not True or any(closure.get(key) != [] for key in ("remaining", "groupMembers", "escapes")):
            raise DeliveryError("closure-incomplete")
    return True


def export_app(evidence, output, result, run_id, attempt):
    retained = evidence / "retained"
    manifest_bytes = read_file(retained, MANIFEST, MAX_PUBLIC_BYTES)
    checksum_bytes = read_file(retained, "SHA256SUMS", 1024)
    manifest = json.loads(manifest_bytes)
    artifact = result["artifact"]
    if digest(manifest_bytes) != artifact["manifestSHA256"] or digest(checksum_bytes) != artifact["checksumsSHA256"]:
        raise DeliveryError("retention-hash")
    if manifest.get("source") != {"commitSHA": SOURCE_COMMIT, "treeSHA": SOURCE_TREE} or manifest.get("ci") != {"runID": run_id, "runAttempt": attempt}:
        raise DeliveryError("manifest-identity")
    limits = manifest.get("limits", {})
    if limits.get("validationMode") != "unsigned-ci-package-validation-only" or any(limits.get(key) is not False for key in ("codeSigningPerformed", "releaseBuildProvenanceCreated", "distributionEligible", "compilerAttestation", "nativeAdmission")):
        raise DeliveryError("manifest-scope")
    archive = manifest["archive"]
    if archive != artifact["archive"] or archive["file"] != ARCHIVE or not re.fullmatch(r"[0-9a-f]{64}", archive["sha256"]) or type(archive["sizeBytes"]) is not int or not 0 < archive["sizeBytes"] <= MAX_ARCHIVE_BYTES:
        raise DeliveryError("archive-identity")
    if manifest["app"]["bundleIdentifier"] != "org.imrse.app" or manifest["app"]["architecture"] != "arm64" or manifest["app"]["ciValidationReceiptSHA256"] != result["product"]["receiptSHA256"]:
        raise DeliveryError("app-identity")
    expected_checksums = f"{archive['sha256']}  {ARCHIVE}\n{digest(manifest_bytes)}  {MANIFEST}\n".encode()
    if checksum_bytes != expected_checksums:
        raise DeliveryError("checksums-content")
    path = retained / ARCHIVE
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size != archive["sizeBytes"]:
        raise DeliveryError("archive-shape")
    output.mkdir(mode=0o700)
    hasher = hashlib.sha256()
    count = 0
    with path.open("rb") as source, (output / (ARCHIVE + ".partial")).open("xb") as destination:
        while True:
            block = source.read(1024**2)
            if not block:
                break
            count += len(block)
            if count > archive["sizeBytes"]:
                raise DeliveryError("archive-growth")
            hasher.update(block)
            destination.write(block)
    if count != archive["sizeBytes"] or hasher.hexdigest() != archive["sha256"]:
        raise DeliveryError("archive-hash")
    (output / MANIFEST).write_bytes(manifest_bytes)
    (output / "SHA256SUMS").write_bytes(checksum_bytes)
    (output / (ARCHIVE + ".partial")).rename(output / ARCHIVE)


def export(evidence, output, control_commit, run_id, attempt):
    if not re.fullmatch(r"[0-9a-f]{40}", control_commit) or not all(re.fullmatch(r"[1-9][0-9]*", value) for value in (run_id, attempt)):
        raise DeliveryError("expected-identity")
    output.mkdir(mode=0o700)
    receipts = output / "receipts"
    receipts.mkdir(mode=0o700)
    raw_digest = None
    failed = False
    receipt = public_receipt({"status": "unavailable"}, control_commit, run_id, attempt)
    try:
        raw = read_file(evidence, "hosted-combined-result.json", MAX_RESULT_BYTES)
        raw_digest = digest(raw)
        result = json.loads(raw)
        receipt = public_receipt(result, control_commit, run_id, attempt)
        if validate_success(result, control_commit, run_id, attempt):
            export_app(evidence, output / "app", result, run_id, attempt)
            receipt["delivery"]["appIncluded"] = True
    except Exception as error:
        failed = True
        receipt["delivery"]["exportFailureSHA256"] = digest((type(error).__name__ + ":" + str(error)).encode())
    receipt["delivery"]["exportStatus"] = "failed" if failed else "complete"
    receipt["delivery"]["rawResultSHA256"] = raw_digest
    payload = json.dumps(receipt, indent=2, sort_keys=True).encode() + b"\n"
    if len(payload) > MAX_PUBLIC_BYTES:
        raise DeliveryError("public-receipt-size")
    (receipts / "hosted-combined-receipt.json").write_bytes(payload)
    summary = json.dumps({"status": receipt.get("status"), "exportStatus": receipt["delivery"]["exportStatus"], "appIncluded": receipt["delivery"]["appIncluded"], "rawLogsIncluded": False, "receiptSHA256": digest(payload)}, sort_keys=True) + "\n"
    (receipts / "build-summary.txt").write_text(summary, encoding="utf-8")
    print(summary, end="")
    return int(failed)


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--control-commit", required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--run-attempt", required=True)
    args = parser.parse_args(argv)
    try:
        return export(args.evidence, args.output, args.control_commit, args.run_id, args.run_attempt)
    except Exception:
        print('{"exportStatus":"failed","appIncluded":false,"receiptAvailable":false}')
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
