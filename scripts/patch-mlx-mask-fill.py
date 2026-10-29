#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import platform
import re
import stat
import subprocess
import sys
from pathlib import Path, PurePosixPath


sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci_approval
import ci_mlx_patch_sources
from package_local_candidate import strict_json_loads


APPROVED_MLX_PATCH = {
    "schemaVersion": 1,
    "identity": "mlx-swift",
    "version": "0.31.6",
    "url": "https://github.com/ml-explore/mlx-swift",
    "revision": "0bb916c67f4b9e5c682cbe02a42c701c93ab5021",
    "license": {
        "path": "LICENSE",
        "sha256": "44326a4ea062241ae6fc26ee2ec90bdc81af7eb7b9d3966181b733fa69d42057",
    },
    "files": [
        {
            "path": "Source/MLX/MLXArray+maskFill.swift",
            "originalSHA256": "5e6ae4e844cbd2ea61032a3c45e5281248072a350be012ae6409ade2250920fe",
            "patchedSHA256": "391cde3f3480fe9fd434b5ce4bcd4a55166e06db18a7c5a0e1577f43f06a4063",
            "originalSize": 495,
            "patchedSize": 491,
            "oldText": "guard let info = dtype.finfo else {",
            "newText": "guard dtype.finfo != nil else {",
        },
        {
            "path": "Source/MLXNN/Module.swift",
            "originalSHA256": "41949db53925fc89ad79459d4ca8f16b051ae9f1470c1a385d2728626c210de6",
            "patchedSHA256": "033f0ef3fddac02858dc9591b4ffcd8b45749cdb881641436526d867147341cc",
            "originalSize": 61690,
            "patchedSize": 61708,
            "replacements": [
                {
                    "oldText": "if let value = value as? T {\n                return value",
                    "newText": "if let value = (value as Any) as? T {\n                return value",
                },
                {
                    "oldText": "if let module = module as? T {\n                return module",
                    "newText": "if let module = (module as Any) as? T {\n                return module",
                },
            ],
        },
    ],
}

ROOT_LOCK = "Package.resolved"
EXTENSION_HELPER = "scripts/enable-ci-extensions.py"
EXPECTED_PACKAGE_IDS = {"mlx-swift", "mlx-swift-lm"}
NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
MAX_FILE_SIZE = 4 * 1024 * 1024


class PatchError(ValueError):
    pass


def _need(condition, message):
    if not condition:
        raise PatchError(message)


def _sha256(contents):
    return hashlib.sha256(contents).hexdigest()


def _within(path, parent):
    try:
        path.relative_to(parent)
        return True
    except ValueError:
        return False


def _require_host():
    env = os.environ
    if platform.system() != "Darwin" or platform.machine().lower() not in {"arm64", "aarch64"}:
        raise PatchError("requires Darwin arm64")
    if (env.get("GITHUB_ACTIONS", "").lower() != "true"
            or env.get("RUNNER_ENVIRONMENT", "").lower() != "github-hosted"
            or env.get("RUNNER_OS", "").lower() != "macos"
            or env.get("RUNNER_ARCH", "").lower() != "arm64"):
        raise PatchError("requires a hosted GitHub Actions runner")


def _git(checkout, *args):
    env = os.environ.copy()
    env["GIT_OPTIONAL_LOCKS"] = "0"
    try:
        return subprocess.check_output(["git", "-C", str(checkout), *args], stderr=subprocess.DEVNULL,
                                        env=env, timeout=20)
    except (OSError, subprocess.SubprocessError) as error:
        raise PatchError("unable to inspect Git checkout") from error


def _git_text(checkout, *args):
    try:
        return _git(checkout, *args).decode("utf-8").rstrip("\r\n")
    except UnicodeDecodeError as error:
        raise PatchError("invalid Git metadata") from error


def _safe_relative(root, relative):
    path = PurePosixPath(relative)
    _need(path.parts and not path.is_absolute() and ".." not in path.parts and "\\" not in relative,
          "unsafe approved path")
    current = root
    for part in path.parts[:-1]:
        current /= part
        _need(not current.is_symlink() and current.is_dir(), "unsafe approved path")
    result = current / path.parts[-1]
    _need(not result.is_symlink(), "unsafe approved path")
    return result


def _read_regular(path):
    try:
        fd = os.open(path, os.O_RDONLY | NOFOLLOW)
        with os.fdopen(fd, "rb") as source:
            metadata = os.fstat(source.fileno())
            _need(stat.S_ISREG(metadata.st_mode) and metadata.st_size <= MAX_FILE_SIZE, "unsafe file")
            contents = source.read(MAX_FILE_SIZE + 1)
            _need(len(contents) == metadata.st_size, "file changed while being read")
            return contents, stat.S_IMODE(metadata.st_mode)
    except OSError as error:
        raise PatchError("file is unavailable or unsafe") from error


def _json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def _absolute_external_file(value, root, *, must_exist):
    candidate = Path(value).expanduser()
    _need(candidate.is_absolute() and candidate.name not in {"", ".", ".."}, "receipt must be an absolute file path")
    try:
        parent = candidate.parent.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise PatchError("invalid receipt directory") from error
    _need(parent.is_dir(), "invalid receipt directory")
    path = parent / candidate.name
    _need(not path.is_symlink() and not _within(path, root), "receipt must be outside the source checkout")
    if must_exist:
        _need(path.is_file(), "receipt is missing or invalid")
    else:
        _need(not path.exists(), "refusing to overwrite an existing receipt")
    return path


def _read_json(path, label):
    raw, _ = _read_regular(path)
    try:
        value = strict_json_loads(raw)
    except (TypeError, ValueError) as error:
        raise PatchError(f"invalid {label} JSON") from error
    return raw, value


def _root_approvals(root):
    top = Path(_git_text(root, "rev-parse", "--show-toplevel")).resolve()
    _need(top == root, "source root is not a Git checkout")
    head = _git_text(root, "rev-parse", "HEAD")
    _need(re.fullmatch(r"[0-9a-f]{40}", head) is not None, "source root HEAD is invalid")
    try:
        packages = ci_approval.committed_literal(root, head, EXTENSION_HELPER, "PACKAGES")
        expected_extensions = ci_approval.approved_extensions(root, head)
        committed_patch = ci_approval.approved_mlx_patch(root, head)
    except (AttributeError, KeyError, TypeError) as error:
        raise PatchError("committed CI approvals are unavailable") from error
    _need(committed_patch == APPROVED_MLX_PATCH,
          "committed MLX approval changed")
    _need(isinstance(packages, dict) and set(packages) == EXPECTED_PACKAGE_IDS,
          "committed helper package set changed")
    _need(isinstance(expected_extensions, dict) and expected_extensions.get("schemaVersion") == 1
          and isinstance(expected_extensions.get("packages"), list)
          and len(expected_extensions["packages"]) == 2, "invalid committed extensions")
    return head, packages, expected_extensions


def _validate_lock(root, packages):
    lock_path = root / ROOT_LOCK
    _need(not lock_path.is_symlink() and lock_path.is_file(), "root lock is unavailable or unsafe")
    raw, lock = _read_json(lock_path, "root Package.resolved")
    pins = lock.get("pins") if isinstance(lock, dict) else None
    _need(isinstance(pins, list), "root lock has no pins")
    for identity, spec in packages.items():
        _need(isinstance(spec, dict) and set(spec) == {"url", "version", "revision", "target", "registry", "sources"},
              "invalid package approval")
        expected = ("remoteSourceControl", spec["url"], spec["version"], spec["revision"])
        if identity == "mlx-swift":
            patch_pin = tuple(APPROVED_MLX_PATCH[key] for key in ("url", "version", "revision"))
            _need(expected[1:] == patch_pin, "committed MLX pin changed")
            expected = (expected[0], *patch_pin)
        matches = [pin for pin in pins if isinstance(pin, dict) and pin.get("identity") == identity]
        _need(len(matches) == 1, "unexpected root pin count")
        pin = matches[0]
        state = pin.get("state")
        _need(set(pin) == {"identity", "kind", "location", "state"}
              and isinstance(state, dict) and set(state) == {"version", "revision"}
              and (pin["kind"], pin["location"], state["version"], state["revision"]) == expected,
              "root pin changed")
    return raw


def _validate_extension_receipt(path, expected):
    raw, receipt = _read_json(path, "extension receipt")
    _need(receipt == expected and raw == _json_bytes(expected),
          "extension receipt does not match the approval")


def _check_git_identity(checkout, revision, *, clean):
    top = Path(_git_text(checkout, "rev-parse", "--show-toplevel")).resolve()
    head = _git_text(checkout, "rev-parse", "HEAD")
    _need(top == checkout and head == revision, "package checkout pin changed")
    if clean:
        _need(not _git(checkout, "status", "--porcelain=v1", "-z", "--untracked-files=all"),
              "package checkout is dirty")


def _validate_extension_sources(root, packages, *, allow_mlx_patch):
    build = root / ".build"
    checkouts = build / "checkouts"
    _need(not build.is_symlink() and build.is_dir() and not checkouts.is_symlink() and checkouts.is_dir(),
          "root package checkouts are unavailable")
    for identity, spec in packages.items():
        checkout = checkouts / identity
        _need(not checkout.is_symlink() and checkout.is_dir(), "package checkout is unavailable")
        _check_git_identity(checkout, spec["revision"], clean=not (allow_mlx_patch and identity == "mlx-swift"))
        sources = spec["sources"]
        _need(isinstance(sources, dict) and sources, "invalid committed source approval")
        for relative, digest in sources.items():
            _need(isinstance(digest, str) and re.fullmatch(r"[0-9a-f]{64}", digest) is not None,
                  "invalid committed source hash")
            path = _safe_relative(checkout, relative)
            contents, _ = _read_regular(path)
            _need(_sha256(contents) == digest, "reviewed extension source changed")


def _verify_license(checkout):
    license_record = APPROVED_MLX_PATCH["license"]
    path = _safe_relative(checkout, license_record["path"])
    contents, _ = _read_regular(path)
    _need(_sha256(contents) == license_record["sha256"], "MLX license changed")


def run(source_root, receipt_path, extension_receipt_path, verify_only=False):
    _require_host()
    try:
        root = Path(source_root).expanduser().resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise PatchError("source root is unavailable") from error
    _need(root.is_dir(), "invalid source root")
    receipt = _absolute_external_file(receipt_path, root, must_exist=verify_only)
    extension_receipt = _absolute_external_file(extension_receipt_path, root, must_exist=True)
    _need(receipt != extension_receipt, "MLX patch receipt must be separate from the extension receipt")
    head, packages, expected_extensions = _root_approvals(root)
    lock_bytes = _validate_lock(root, packages)
    _validate_extension_receipt(extension_receipt, expected_extensions)
    _validate_extension_sources(root, packages, allow_mlx_patch=verify_only)
    checkout = root / ".build/checkouts/mlx-swift"
    _check_git_identity(checkout, APPROVED_MLX_PATCH["revision"], clean=not verify_only)
    _verify_license(checkout)
    plans = ci_mlx_patch_sources.preflight(checkout, APPROVED_MLX_PATCH["files"], _safe_relative,
                                           _read_regular, _git, _need, verify_only=verify_only)
    receipt_bytes = _json_bytes(APPROVED_MLX_PATCH)
    if verify_only:
        ci_mlx_patch_sources.verify(checkout, plans, _read_regular, _git, _need)
        stored, _ = _read_regular(receipt)
        _need(stored == receipt_bytes, "MLX patch receipt does not match the approved literal")
        _need(_validate_lock(root, packages) == lock_bytes, "root Package.resolved changed during verification")
        _verify_license(checkout)
        _need(_git_text(root, "rev-parse", "HEAD") == head, "source root HEAD changed during verification")
        return

    def validate_after_patch():
        _need(_validate_lock(root, packages) == lock_bytes, "root Package.resolved changed during patching")
        _verify_license(checkout)
        _need(_git_text(root, "rev-parse", "HEAD") == head, "source root HEAD changed during patching")
        _validate_extension_sources(root, packages, allow_mlx_patch=True)

    ci_mlx_patch_sources.apply(checkout, plans, receipt, receipt_bytes, _read_regular, _git, _need,
                               validate_after_patch)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("--extension-receipt", required=True, type=Path)
    parser.add_argument("--verify-only", action="store_true")
    try:
        args = parser.parse_args()
        run(args.source_root, args.receipt, args.extension_receipt, args.verify_only)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
