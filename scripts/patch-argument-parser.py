import argparse
import hashlib
import json
import os
import platform
import stat
import subprocess
import sys
import tempfile
from pathlib import Path


LICENSE_SIZE = 11751

APPROVED_PATCH = {
    "schemaVersion": 1,
    "identity": "swift-argument-parser",
    "version": "1.8.2",
    "url": "https://github.com/apple/swift-argument-parser",
    "revision": "6a52f3251125d74daf04fcbd5e6f08a75d074382",
    "license": {
        "path": "LICENSE.txt",
        "sha256": "770af8291f708538d8ff885a0bbc4e045cd700531741c4f99528d435c14d7f55",
    },
    "files": [
        {
            "path": "Sources/ArgumentParser/Parsable Types/ParsableArguments.swift",
            "originalSHA256": "1ad16fa584662bfe539dbbce2e2b9d305af40856f433a60439ecad71e4c9087e",
            "patchedSHA256": "fe0fe8c9f106514a8356f5b6a4e91b4d6a276f5c0fbd20cac17614b439830947",
            "originalSize": 12518,
            "patchedSize": 12452,
            "removedAnnotation": '@available(*, deprecated, message: "Use _errorPrefix instead.")',
        },
        {
            "path": "Sources/ArgumentParserToolInfo/ToolInfo.swift",
            "originalSHA256": "fb87e458c14843a319ba76ad5a95aff76628215251318d0c1b9d68e083235dd0",
            "patchedSHA256": "bcc212e4059ee0797ba0338bf40bb89d83d584ea39d99a33a44b28ccc614547b",
            "originalSize": 9575,
            "patchedSize": 9513,
            "removedAnnotation": '@available(*, deprecated, message: "Use custom instead.")',
        },
    ],
}

PATCH_HUNKS = (
    (
        b'  @available(*, deprecated, message: "Use _errorPrefix instead.")\n',
        b"",
    ),
    (
        b'    @available(*, deprecated, message: "Use custom instead.")\n',
        b"",
    ),
)

LOCK_KIND = "remoteSourceControl"
CHECKOUT_PATH = Path(".build/checkouts/swift-argument-parser")


class PatchError(Exception):
    pass


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
        raise PatchError("compatibility repair requires a Darwin arm64 host")
    if (
        env.get("GITHUB_ACTIONS", "").lower() != "true"
        or env.get("RUNNER_ENVIRONMENT", "").lower() != "github-hosted"
        or env.get("RUNNER_OS", "").lower() != "macos"
        or env.get("RUNNER_ARCH", "").lower() != "arm64"
    ):
        raise PatchError("compatibility repair requires a hosted GitHub Actions runner")


def _run_git(checkout, *arguments):
    env = os.environ.copy()
    env["GIT_OPTIONAL_LOCKS"] = "0"
    try:
        result = subprocess.run(
            ["git", "-C", str(checkout), *arguments],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
        )
    except (OSError, RuntimeError) as error:
        raise PatchError("unable to inspect the dependency checkout") from error
    if result.returncode != 0:
        raise PatchError("unable to inspect the dependency checkout")
    return result.stdout


def _decode_git_text(value):
    try:
        return value.decode("utf-8").rstrip("\r\n")
    except UnicodeDecodeError as error:
        raise PatchError("dependency Git metadata is not valid UTF-8") from error


def _resolve_paths(source_root, receipt_path, verify_only):
    try:
        root = Path(source_root).expanduser().resolve(strict=True)
        checkout_entry = root / CHECKOUT_PATH
        checkout = checkout_entry.resolve(strict=True)
        receipt_input = Path(receipt_path).expanduser()
        if not receipt_input.is_absolute():
            raise PatchError("receipt path must be absolute")
        receipt_parent = receipt_input.parent.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise PatchError("source root, checkout, or receipt directory is unavailable") from error
    if not root.is_dir() or checkout != checkout_entry or not checkout.is_dir():
        raise PatchError("dependency checkout must be ROOT/.build/checkouts/swift-argument-parser")
    if receipt_input.name in {"", ".", ".."}:
        raise PatchError("receipt path must name a file")
    receipt = receipt_parent / receipt_input.name
    if receipt.is_symlink() or _within(receipt, root) or _within(receipt, checkout):
        raise PatchError("receipt must be a nonsymlink file outside the source root")
    if verify_only:
        if not receipt.is_file():
            raise PatchError("verification receipt is missing")
    elif receipt.exists():
        raise PatchError("refusing to overwrite an existing receipt")
    return root, checkout, receipt


def _read_lock(root):
    lock_path = root / "Package.resolved"
    if lock_path.is_symlink() or not lock_path.is_file():
        raise PatchError("root Package.resolved is unavailable or invalid")
    try:
        contents = lock_path.read_bytes()
        lock = json.loads(contents)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise PatchError("root Package.resolved is unavailable or invalid") from error
    if not isinstance(lock, dict):
        raise PatchError("root Package.resolved has no pins array")
    pins = lock.get("pins")
    if not isinstance(pins, list):
        raise PatchError("root Package.resolved has no pins array")
    matches = [pin for pin in pins if isinstance(pin, dict) and pin.get("identity") == APPROVED_PATCH["identity"]]
    if len(matches) != 1:
        raise PatchError("root Package.resolved does not contain one swift-argument-parser pin")
    pin = matches[0]
    state = pin.get("state")
    if (
        pin.get("kind") != LOCK_KIND
        or pin.get("location") != APPROVED_PATCH["url"]
        or not isinstance(state, dict)
        or state.get("version") != APPROVED_PATCH["version"]
        or state.get("revision") != APPROVED_PATCH["revision"]
    ):
        raise PatchError("root Package.resolved does not match the approved dependency pin")
    return contents


def _resolve_file(checkout, relative_path):
    relative = Path(relative_path)
    if relative.is_absolute() or ".." in relative.parts:
        raise PatchError("approved patch contains an unsafe relative path")
    path = checkout / relative
    try:
        if path.parent.resolve(strict=True) != path.parent or path.is_symlink():
            raise PatchError("dependency source path must not traverse a symlink")
        metadata = path.lstat()
    except (OSError, RuntimeError) as error:
        raise PatchError("approved dependency source file is unavailable") from error
    if not stat.S_ISREG(metadata.st_mode):
        raise PatchError("approved dependency source path is not a regular file")
    return path, stat.S_IMODE(metadata.st_mode)


def _verify_checkout_identity(checkout):
    top_level = Path(_decode_git_text(_run_git(checkout, "rev-parse", "--show-toplevel"))).resolve()
    revision = _decode_git_text(_run_git(checkout, "rev-parse", "HEAD"))
    if top_level != checkout or revision != APPROVED_PATCH["revision"]:
        raise PatchError("dependency checkout is not the approved upstream revision")


def _require_clean_checkout(checkout):
    status = _run_git(checkout, "status", "--porcelain=v1", "-z", "--untracked-files=all")
    if status:
        raise PatchError("dependency checkout must be clean before applying the repair")


def _require_exact_patch_diff(checkout):
    expected = sorted(item["path"] for item in APPROVED_PATCH["files"])
    changed = _run_git(checkout, "diff", "--name-only", "-z", "HEAD", "--")
    status = _run_git(checkout, "status", "--porcelain=v1", "-z", "--untracked-files=all")
    expected_paths = b"".join(os.fsencode(path) + b"\0" for path in expected)
    expected_status = b"".join(b" M " + os.fsencode(path) + b"\0" for path in expected)
    if changed != expected_paths or status != expected_status:
        raise PatchError("dependency checkout diff must contain exactly the approved source files")
    if _run_git(checkout, "diff", "--summary", "-z", "HEAD", "--"):
        raise PatchError("dependency source file modes changed")


def _receipt_bytes():
    return (json.dumps(APPROVED_PATCH, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def _verify_license(checkout):
    license_spec = APPROVED_PATCH["license"]
    path, _ = _resolve_file(checkout, license_spec["path"])
    try:
        contents = path.read_bytes()
    except OSError as error:
        raise PatchError("upstream dependency license is unavailable") from error
    if len(contents) != LICENSE_SIZE or _sha256(contents) != license_spec["sha256"]:
        raise PatchError("upstream dependency license does not match the approved source")


def _patch_plan(checkout):
    if len(PATCH_HUNKS) != len(APPROVED_PATCH["files"]):
        raise PatchError("approved patch hunks do not match the receipt file list")
    plan = []
    for file_spec, (old_hunk, new_hunk) in zip(APPROVED_PATCH["files"], PATCH_HUNKS):
        relative_path = file_spec["path"]
        path, mode = _resolve_file(checkout, relative_path)
        try:
            original = path.read_bytes()
        except OSError as error:
            raise PatchError("approved dependency source file is unavailable") from error
        if len(original) != file_spec["originalSize"] or _sha256(original) != file_spec["originalSHA256"]:
            raise PatchError("dependency source does not match the approved upstream bytes")
        annotation = file_spec["removedAnnotation"].encode("utf-8")
        if old_hunk.rstrip(b"\n").lstrip() != annotation or not old_hunk.endswith(b"\n") or new_hunk:
            raise PatchError("approved hunk must remove only its named deprecation annotation")
        if original.count(old_hunk) != 1:
            raise PatchError("approved source hunk must occur exactly once")
        patched = original.replace(old_hunk, new_hunk, 1)
        if len(patched) != file_spec["patchedSize"] or _sha256(patched) != file_spec["patchedSHA256"]:
            raise PatchError("approved source hunk does not produce the recorded patched bytes")
        plan.append((relative_path, path, original, patched, mode))
    return plan


def _verify_patched_checkout(checkout):
    for file_spec in APPROVED_PATCH["files"]:
        path, _ = _resolve_file(checkout, file_spec["path"])
        try:
            contents = path.read_bytes()
        except OSError as error:
            raise PatchError("approved dependency source file is unavailable") from error
        if len(contents) != file_spec["patchedSize"] or _sha256(contents) != file_spec["patchedSHA256"]:
            raise PatchError("dependency source does not match the approved patched bytes")
    _require_exact_patch_diff(checkout)


def _write_temp(path, contents, mode):
    descriptor, name = tempfile.mkstemp(prefix=".imrse-argument-parser-", dir=str(path.parent))
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(contents)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, mode)
        return temporary
    except Exception:
        if temporary.exists():
            temporary.unlink()
        raise


def _atomic_replace(path, contents, mode):
    temporary = _write_temp(path, contents, mode)
    try:
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def _create_receipt(path, contents):
    temporary = _write_temp(path, contents, 0o644)
    try:
        os.link(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def _rollback(applied):
    errors = []
    for path, original, patched, mode in reversed(applied):
        try:
            if path.read_bytes() != patched:
                errors.append(path.name)
                continue
            _atomic_replace(path, original, mode)
            if path.read_bytes() != original or stat.S_IMODE(path.lstat().st_mode) != mode:
                errors.append(path.name)
        except OSError:
            errors.append(path.name)
    return errors


def patch_dependency(source_root, receipt_path, verify_only=False):
    _require_host()
    root, checkout, receipt = _resolve_paths(source_root, receipt_path, verify_only)
    lock_contents = _read_lock(root)
    _verify_checkout_identity(checkout)
    _verify_license(checkout)
    expected_receipt = _receipt_bytes()
    if verify_only:
        _verify_patched_checkout(checkout)
        try:
            receipt_contents = receipt.read_bytes()
        except OSError as error:
            raise PatchError("verification receipt is unavailable") from error
        if receipt_contents != expected_receipt:
            raise PatchError("verification receipt does not match the approved patch contract")
        if _read_lock(root) != lock_contents:
            raise PatchError("root Package.resolved changed during verification")
        return APPROVED_PATCH

    plan = _patch_plan(checkout)
    _require_clean_checkout(checkout)
    staged = []
    applied = []
    receipt_created = False
    try:
        for relative_path, path, original, patched, mode in plan:
            staged.append((path, original, patched, mode, _write_temp(path, patched, mode)))
        if _read_lock(root) != lock_contents:
            raise PatchError("root Package.resolved changed before source replacement")
        for path, original, patched, mode, temporary in staged:
            if path.read_bytes() != original or stat.S_IMODE(path.lstat().st_mode) != mode:
                raise PatchError("dependency source changed before atomic replacement")
            os.replace(temporary, path)
            applied.append((path, original, patched, mode))
        _verify_patched_checkout(checkout)
        for _, path, _, _, mode in plan:
            if stat.S_IMODE(path.lstat().st_mode) != mode:
                raise PatchError("dependency source mode was not preserved")
        if _read_lock(root) != lock_contents:
            raise PatchError("root Package.resolved changed during source replacement")
        _create_receipt(receipt, expected_receipt)
        receipt_created = True
        if receipt.read_bytes() != expected_receipt:
            raise PatchError("written compatibility receipt failed exact-byte verification")
        return APPROVED_PATCH
    except Exception as error:
        rollback_errors = _rollback(applied)
        if receipt_created and receipt.exists() and receipt.read_bytes() == expected_receipt:
            receipt.unlink()
        if rollback_errors:
            raise PatchError("patch failed and source rollback was incomplete") from error
        if isinstance(error, PatchError):
            raise
        raise PatchError("atomic compatibility repair failed") from error
    finally:
        for _, _, _, _, temporary in staged:
            if temporary.exists():
                temporary.unlink()


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", required=True)
    parser.add_argument("--receipt", required=True)
    parser.add_argument("--verify-only", action="store_true")
    arguments = parser.parse_args(argv)
    try:
        patch_dependency(arguments.source_root, arguments.receipt, arguments.verify_only)
    except PatchError as error:
        print(f"patch-argument-parser: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
