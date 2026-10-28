#!/usr/bin/env python3
import argparse
import json
import os
import platform
import sys
import tarfile
from pathlib import Path

import package_local_candidate as package

TESTS = {
    "callbackDeliveryAndOrder": "URLSession.AsyncBytes delivers public callbacks in order",
    "closeFromFirstMessageStopsStream": "Closing in the first message callback stops later data and reconnection",
    "closeFromOpenPreventsLateCallbacks": "Closing from open before byte consumption suppresses late callbacks",
}
RECEIPT = "CI-PACKAGE-VALIDATION.json"


class ExportError(Exception):
    pass


def need(value, message):
    if not value:
        raise ExportError(message)


def git(root, *args):
    return package.run(["git", "-C", str(root), *args]).strip()


def source(root, expected):
    commit = git(root, "rev-parse", "HEAD")
    need(len(expected) == 40 and all(c in "0123456789abcdefABCDEF" for c in expected) and
         commit.lower() == expected.lower(), "checkout differs from selected workflow SHA")
    tree = git(root, "rev-parse", f"{commit}^{{tree}}")
    need(not git(root, "status", "--porcelain", "--untracked-files=all"),
         "source checkout changed during CI validation")
    return commit, tree


def test_count(path):
    lines = Path(path).read_text().splitlines()
    for function, title in TESTS.items():
        events = [line for line in lines if "Test " in line and (function in line or title in line)]
        need(len(events) == 2 and sum("started" in line for line in events) == 1 and
             sum("passed" in line for line in events) == 1, f"EventSource test did not run and pass: {function}")
    return len(TESTS)


def app_bundle(path, root, commit, tree):
    path = Path(path).expanduser()
    need(not path.is_symlink(), "app bundle must not be a symlink")
    bundle, info = package.validate_built_app_bundle(path, package.read_source_info(root))
    resources = bundle / "Contents/Resources"
    files = (
        next((p for p in resources.rglob("default.metallib") if p.is_file() and p.stat().st_size), None),
        next((p for p in resources.rglob("imrse-menubar-template.pdf") if p.is_file() and p.parent.name == "Brand" and p.stat().st_size), None),
        resources / "imrse_ImrseLocal.bundle/Contents/Resources/Qwen3-APACHE-LICENSE.txt",
        resources / "ThirdPartyLicenses/EventSource-LICENSE.md",
        resources / "ThirdPartyLicenses/EventSource-PROVENANCE.md",
    )
    for item, label in zip(files, ("default.metallib", "Brand menu PDF", "Qwen license", "EventSource license", "EventSource provenance")):
        need(item is not None and item.is_file() and item.stat().st_size, f"missing nonempty {label}")
    vendor = root / "Vendor/EventSource"
    need(files[3].read_bytes() == (vendor / "LICENSE.md").read_bytes(), "EventSource license differs from vendor source")
    need(files[4].read_bytes() == (vendor / "PROVENANCE.md").read_bytes(), "EventSource provenance differs from vendor source")
    try:
        receipt = json.loads((resources / RECEIPT).read_text())
    except (OSError, ValueError) as error:
        raise ExportError("app is missing its CI package validation receipt") from error
    need(receipt.get("validationMode") == "unsigned-ci-package-validation-only" and
         receipt.get("distributionEligible") is False and receipt.get("codeSigningPerformed") is False and
         receipt.get("releaseBuildProvenanceCreated") is False, "app is not marked unsigned CI-only")
    need(receipt.get("source") == {"commitSHA": commit, "treeSHA": tree}, "CI receipt is bound to different source")
    arch = receipt.get("product", {}).get("machoArchitectures")
    need(receipt.get("product", {}).get("hostArchitecture") == "arm64" and isinstance(arch, dict) and
         arch and set(arch.values()) == {"arm64"} and platform.machine().lower() in {"arm64", "aarch64"},
         "CI receipt does not prove an arm64-only candidate")
    return bundle, info


def export(args, root, commit, tree, tests):
    output = Path(args.output_dir).expanduser().resolve(strict=True)
    need(not output.is_relative_to(root), "candidate output must be outside source checkout")
    bundle, info = app_bundle(args.app, root, commit, tree)
    archive, manifest = output / "imrse-ci-candidate-arm64.tar.gz", output / "candidate-provenance.json"
    need(not archive.exists() and not manifest.exists(), "candidate output already exists")
    inventory = package.bundle_tree_entries(bundle)
    with tarfile.open(archive, "x:gz") as tar:
        tar.add(bundle, arcname="imrse.app", recursive=True)
    archive_hash = package.sha256_file(archive)
    payload = {
        "schemaVersion": 1, "scope": "unsigned CI validation only; not distribution eligible or compiler attestation",
        "source": {"commitSHA": commit, "treeSHA": tree, "selectedCommitSHA": args.expected_commit,
                   "eventSHA": os.getenv("GITHUB_SHA")},
        "ci": {key: os.getenv(env) for key, env in (("workflow", "GITHUB_WORKFLOW"), ("job", "GITHUB_JOB"),
               ("runID", "GITHUB_RUN_ID"), ("runAttempt", "GITHUB_RUN_ATTEMPT"), ("eventName", "GITHUB_EVENT_NAME"))},
        "host": {"os": "macOS", "architecture": "arm64", "minimumMacOS": info["LSMinimumSystemVersion"]},
        "toolchain": {"xcode": Path(args.xcode_version_log).read_text().strip(),
                      "swift": Path(args.swift_version_log).read_text().strip()},
        "build": {"configuration": "release", "system": "swiftbuild", "jobs": 1, "warningsAsErrors": True,
                  "wholeModuleOptimization": True, "eventsourceTestsExecuted": tests,
                  "buildLogSHA256": package.sha256_file(args.build_log),
                  "eventsourceTestLogSHA256": package.sha256_file(args.eventsource_test_log)},
        "dependencies": {"rootGraphSHA256": package.sha256_file(args.graph_json),
                          "packageResolvedSHA256": package.sha256_file(root / "Package.resolved"),
                          "vendorEventSourceTreeSHA256": package.bundle_tree_sha256(root / "Vendor/EventSource")},
        "app": {"bundleTreeSHA256": package.bundle_tree_sha256(bundle), "inventory": inventory},
        "archive": {"file": archive.name, "sha256": archive_hash, "format": "tar.gz; Unix modes preserved"},
    }
    manifest.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    (output / f"{archive.name}.sha256").write_text(f"{archive_hash}  {archive.name}\n")
    (output / f"{manifest.name}.sha256").write_text(f"{package.sha256_file(manifest)}  {manifest.name}\n")
    print(f"Unsigned arm64 candidate: {archive}\nProvenance: {manifest}")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Validate and archive the unsigned macOS CI app candidate")
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--expected-commit", required=True)
    parser.add_argument("--graph-json", required=True, type=Path)
    parser.add_argument("--eventsource-test-log", required=True, type=Path)
    for name in ("app", "output-dir", "swift-version-log", "xcode-version-log", "build-log"):
        parser.add_argument(f"--{name}", type=Path)
    args = parser.parse_args(argv)
    try:
        root = args.source_root.expanduser().resolve(strict=True)
        commit, tree = source(root, args.expected_commit)
        tests = test_count(args.eventsource_test_log)
        need(all((args.app, args.output_dir, args.swift_version_log, args.xcode_version_log, args.build_log)),
             "export needs app, output, toolchain logs, and build log")
        export(args, root, commit, tree, tests)
    except (ExportError, package.PackageError, OSError, ValueError, KeyError, tarfile.TarError) as error:
        print(f"CI candidate export failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
