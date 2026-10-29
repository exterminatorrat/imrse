import difflib
import hashlib
import os
import tempfile
from pathlib import Path


def _line_counts(old, new):
    matcher = difflib.SequenceMatcher(None, old.splitlines(), new.splitlines(), autojunk=False)
    changes = [(i2 - i1, j2 - j1) for tag, i1, i2, j1, j2 in matcher.get_opcodes() if tag != "equal"]
    return sum(old_count for old_count, _ in changes), sum(new_count for _, new_count in changes)


def preflight(checkout, specs, safe_relative, read_regular, git, need, *, verify_only):
    base = {"path", "originalSHA256", "patchedSHA256", "originalSize", "patchedSize"}
    need(isinstance(specs, list) and specs, "invalid approved MLX source list")
    targets = []
    for spec in specs:
        need(isinstance(spec, dict), "invalid approved MLX source")
        if "replacements" in spec:
            need(set(spec) == base | {"replacements"} and isinstance(spec["replacements"], list),
                 "invalid approved MLX replacements")
            hunks = spec["replacements"]
        else:
            need(set(spec) == base | {"oldText", "newText"}, "invalid approved MLX replacement")
            hunks = [{"oldText": spec["oldText"], "newText": spec["newText"]}]
        need(hunks and all(isinstance(hunk, dict) and set(hunk) == {"oldText", "newText"}
                           and isinstance(hunk["oldText"], str) and hunk["oldText"]
                           and isinstance(hunk["newText"], str) and hunk["newText"] != hunk["oldText"]
                           for hunk in hunks), "invalid approved MLX replacement")
        relative = spec["path"]
        need(isinstance(relative, str) and relative, "invalid approved MLX path")
        targets.append((spec, hunks, relative, safe_relative(checkout, relative)))
    need(len({relative for _, _, relative, _ in targets}) == len(targets), "duplicate approved MLX path")
    plans = []
    for spec, hunks, relative, path in targets:
        original = git(checkout, "show", f"HEAD:{relative}")
        need(len(original) == spec["originalSize"]
             and hashlib.sha256(original).hexdigest() == spec["originalSHA256"], "MLX Git preimage changed")
        patched = original
        removed = added = 0
        for hunk in hunks:
            old, new = hunk["oldText"].encode("utf-8"), hunk["newText"].encode("utf-8")
            need(original.count(old) == 1 and patched.count(old) == 1, "approved MLX hunk is not unique")
            old_lines, new_lines = _line_counts(old, new)
            removed += old_lines
            added += new_lines
            patched = patched.replace(old, new, 1)
        need(len(patched) == spec["patchedSize"]
             and hashlib.sha256(patched).hexdigest() == spec["patchedSHA256"],
             "approved MLX hunk produces unexpected bytes")
        current, mode = read_regular(path)
        expected = patched if verify_only else original
        need(current == expected, "MLX source does not match the approved patched bytes" if verify_only
             else "MLX source does not match the approved upstream bytes")
        plans.append({"path": path, "relative": relative, "original": original, "patched": patched,
                      "mode": mode, "removed": removed, "added": added})
    return plans


def _verify_diff(checkout, plans, git, need):
    plans = sorted(plans, key=lambda plan: plan["relative"].encode("utf-8"))
    paths = [plan["relative"].encode("utf-8") for plan in plans]
    names = b"".join(path + b"\0" for path in paths)
    status = b"".join(b" M " + path + b"\0" for path in paths)
    numstat = b"".join(f"{plan['removed']}\t{plan['added']}\t".encode() + plan["relative"].encode("utf-8") + b"\0"
                        for plan in plans)
    need(git(checkout, "diff", "--name-only", "-z", "HEAD", "--") == names
         and git(checkout, "status", "--porcelain=v1", "-z", "--untracked-files=all") == status
         and not git(checkout, "diff", "--summary", "-z", "HEAD", "--")
         and git(checkout, "diff", "--numstat", "-z", "HEAD", "--") == numstat,
         "MLX checkout diff is not the approved source change")


def verify(checkout, plans, read_regular, git, need):
    for plan in plans:
        current, mode = read_regular(plan["path"])
        need(current == plan["patched"] and mode == plan["mode"], "MLX source postcheck failed")
    _verify_diff(checkout, plans, git, need)


def _atomic_replace(path, contents, mode):
    descriptor, temporary_name = tempfile.mkstemp(prefix=".imrse-mlx-mask-fill-", dir=str(path.parent))
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(contents)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def _write_receipt(path, contents, read_regular, need):
    directory = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
                        | getattr(os, "O_NOFOLLOW", 0))
    temporary_name = None
    created = None
    try:
        descriptor, temporary_path = tempfile.mkstemp(prefix=".imrse-mlx-mask-fill-receipt-", dir=str(path.parent))
        temporary_name = Path(temporary_path).name
        with os.fdopen(descriptor, "wb") as output:
            output.write(contents)
            output.flush()
            os.fsync(output.fileno())
            os.fchmod(output.fileno(), 0o644)
            created = os.fstat(output.fileno())
        os.link(temporary_name, path.name, src_dir_fd=directory, dst_dir_fd=directory, follow_symlinks=False)
        actual = os.stat(path.name, dir_fd=directory, follow_symlinks=False)
        need((actual.st_dev, actual.st_ino) == (created.st_dev, created.st_ino),
             "MLX patch receipt changed during creation")
        os.unlink(temporary_name, dir_fd=directory)
        temporary_name = None
        actual, _ = read_regular(path)
        need(actual == contents, "MLX patch receipt readback did not match")
    except Exception as error:
        if created is not None:
            try:
                actual = os.stat(path.name, dir_fd=directory, follow_symlinks=False)
                if (actual.st_dev, actual.st_ino) == (created.st_dev, created.st_ino):
                    os.unlink(path.name, dir_fd=directory)
            except FileNotFoundError:
                pass
            except OSError:
                need(False, "unable to remove an incomplete MLX patch receipt")
        if isinstance(error, OSError):
            need(False, "unable to create the new MLX patch receipt")
        raise
    finally:
        if temporary_name is not None:
            try:
                os.unlink(temporary_name, dir_fd=directory)
            except FileNotFoundError:
                pass
        os.close(directory)


def apply(checkout, plans, receipt, receipt_bytes, read_regular, git, need, validate_after_patch):
    written = []
    try:
        for plan in plans:
            current, mode = read_regular(plan["path"])
            need(current == plan["original"] and mode == plan["mode"], "MLX source changed after preflight")
            written.append(plan)
            _atomic_replace(plan["path"], plan["patched"], mode)
        verify(checkout, plans, read_regular, git, need)
        validate_after_patch()
        _write_receipt(receipt, receipt_bytes, read_regular, need)
    except Exception:
        failed = False
        for plan in reversed(written):
            try:
                current, mode = read_regular(plan["path"])
                if current == plan["patched"] and mode == plan["mode"]:
                    _atomic_replace(plan["path"], plan["original"], mode)
                elif current != plan["original"] or mode != plan["mode"]:
                    failed = True
            except Exception:
                failed = True
        if failed:
            need(False, "unable to safely roll back the MLX source transaction")
        raise
