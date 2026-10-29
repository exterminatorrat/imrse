#!/usr/bin/env python3
import argparse
import ast
import hashlib
import json
import os
import platform
import re
import signal
import stat
import subprocess
import sys
import tempfile
from pathlib import Path, PurePosixPath


APPROVAL_PATH = "scripts/patch-mlx-mask-fill.py"
MODULE_PATH = "Source/MLXNN/Module.swift"
MODULE_CHECKOUT = ".build/checkouts/mlx-swift"
FIXTURE_PATH = "scripts/tests/fixtures/MLXGetterCompatibility.swift"
LOG_NAME = "mlx-getter-compatibility-tests.log"
GENERATED_NAME = "MLXGetterCompatibility.generated.swift"
BINARY_NAME = "mlx-getter-compatibility-tests"
EXPECTED_ORIGINAL_SIZE = 61690
EXPECTED_ORIGINAL_SHA256 = "41949db53925fc89ad79459d4ca8f16b051ae9f1470c1a385d2728626c210de6"
EXPECTED_PATCHED_SIZE = 61708
EXPECTED_PATCHED_SHA256 = "033f0ef3fddac02858dc9591b4ffcd8b45749cdb881641436526d867147341cc"
SUCCESS_MARKER = "MLX getter compatibility checks passed."
MATRIX_SENTINEL = "GETTER_MATRIX_PASSED"
FILE_LIMIT = 4 * 1024 * 1024


class HarnessError(ValueError):
    pass


def _need(condition, message):
    if not condition:
        raise HarnessError(message)


def _sha256(data):
    return hashlib.sha256(data).hexdigest()


def _safe_relative(root, relative):
    _need(isinstance(relative, str), "approved path is invalid")
    path = PurePosixPath(relative)
    _need(path.parts and not path.is_absolute() and ".." not in path.parts and "\\" not in relative,
          "approved path is unsafe")
    current = root
    for part in path.parts[:-1]:
        current /= part
        _need(not current.is_symlink() and current.is_dir(), "approved path is unavailable or unsafe")
    result = current / path.parts[-1]
    _need(not result.is_symlink(), "approved path is unavailable or unsafe")
    return result


def _read_regular(path):
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        with os.fdopen(fd, "rb") as stream:
            metadata = os.fstat(stream.fileno())
            _need(stat.S_ISREG(metadata.st_mode) and metadata.st_size <= FILE_LIMIT, "input file is unsafe")
            data = stream.read(FILE_LIMIT + 1)
            _need(len(data) == metadata.st_size, "input file changed while being read")
            return data
    except OSError as error:
        raise HarnessError("required input file is unavailable or unsafe") from error


def _approved_patch(root):
    helper = _safe_relative(root, APPROVAL_PATH)
    try:
        tree = ast.parse(_read_regular(helper).decode("utf-8"), filename=str(helper))
    except (UnicodeDecodeError, SyntaxError) as error:
        raise HarnessError("approved MLX patch literal is invalid") from error
    assignments = [node.value for node in tree.body if isinstance(node, ast.Assign) and len(node.targets) == 1
                   and isinstance(node.targets[0], ast.Name) and node.targets[0].id == "APPROVED_MLX_PATCH"]
    _need(len(assignments) == 1, "approved MLX patch literal is missing or ambiguous")
    try:
        value = ast.literal_eval(assignments[0])
    except (ValueError, TypeError, SyntaxError) as error:
        raise HarnessError("approved MLX patch is not literal data") from error
    _need(isinstance(value, dict) and value.get("schemaVersion") == 1
          and type(value.get("schemaVersion")) is int
          and value.get("identity") == "mlx-swift" and value.get("version") == "0.31.6"
          and value.get("revision") == "0bb916c67f4b9e5c682cbe02a42c701c93ab5021",
          "approved MLX patch identity changed")
    files = value.get("files")
    _need(isinstance(files, list) and len(files) == 2 and isinstance(files[0], dict)
          and files[0].get("path") == "Source/MLX/MLXArray+maskFill.swift",
          "approved MLX patch file list changed")
    spec = files[1]
    _need(isinstance(spec, dict) and set(spec) == {"path", "originalSHA256", "patchedSHA256",
                                                  "originalSize", "patchedSize", "replacements"}
          and spec.get("path") == MODULE_PATH
          and spec.get("originalSHA256") == EXPECTED_ORIGINAL_SHA256
          and spec.get("originalSize") == EXPECTED_ORIGINAL_SIZE
          and spec.get("patchedSHA256") == EXPECTED_PATCHED_SHA256
          and spec.get("patchedSize") == EXPECTED_PATCHED_SIZE,
          "approved Module.swift source identity changed")
    replacements = spec.get("replacements")
    expected = (("value", "__PARAMETER_GETTER__"), ("module", "__MODULE_GETTER__"))
    _need(isinstance(replacements, list) and len(replacements) == len(expected),
          "approved getter replacement list changed")
    validated = []
    for item, (name, _) in zip(replacements, expected):
        _need(isinstance(item, dict) and set(item) == {"oldText", "newText"}
              and isinstance(item["oldText"], str) and isinstance(item["newText"], str),
              "approved getter replacement is invalid")
        old_lines = [line.strip() for line in item["oldText"].strip().splitlines()]
        new_lines = [line.strip() for line in item["newText"].strip().splitlines()]
        old_cast = f"if let {name} = {name} as? T {{"
        new_cast = f"if let {name} = ({name} as Any) as? T {{"
        _need(len(old_lines) == len(new_lines) and old_lines.count(old_cast) == 1
              and new_lines.count(new_cast) == 1
              and old_lines.count(f"return {name}") == 1 and new_lines.count(f"return {name}") == 1,
              "approved getter replacement does not include the exact cast and return")
        changed = [(old, new) for old, new in zip(old_lines, new_lines) if old != new]
        _need(changed == [(old_cast, new_cast)], "approved getter replacement changes unrelated code")
        validated.append((name, expected[len(validated)][1], "\n".join(old_lines), "\n".join(new_lines)))
    return validated


def _mask_comments_and_strings(source):
    pattern = re.compile(r'//[^\n]*|/\*.*?\*/|"""[\s\S]*?"""|"(?:\\.|[^"\\])*"')
    return pattern.sub(lambda match: "".join("\n" if char == "\n" else " " for char in match.group()), source)


def _matching_brace(masked, opening):
    _need(opening < len(masked) and masked[opening] == "{", "expected a Swift scope")
    depth = 0
    for index in range(opening, len(masked)):
        if masked[index] == "{":
            depth += 1
        elif masked[index] == "}":
            depth -= 1
            if depth == 0:
                return index
    raise HarnessError("Swift scope is not closed")


def _extract_getter(source, class_name):
    masked = _mask_comments_and_strings(source)
    class_matches = list(re.finditer(rf"@propertyWrapper\s+public\s+class\s+{class_name}\s*<\s*T\s*>", masked))
    _need(len(class_matches) == 1, f"{class_name} declaration is missing or ambiguous")
    class_open = masked.find("{", class_matches[0].end())
    _need(class_open >= 0, f"{class_name} declaration is not bounded")
    class_end = _matching_brace(masked, class_open)
    class_mask = masked[class_open + 1:class_end]
    properties = list(re.finditer(r"\bpublic\s+var\s+wrappedValue\s*:\s*T\s*\{", class_mask))
    _need(len(properties) == 1, f"{class_name}.wrappedValue is missing or ambiguous")
    property_open = class_open + 1 + properties[0].end() - 1
    property_end = _matching_brace(masked, property_open)
    accessor_region = masked[property_open + 1:property_end]
    getters = list(re.finditer(r"\bget\s*\{", accessor_region))
    _need(len(getters) == 1, f"{class_name}.wrappedValue getter is missing or ambiguous")
    getter_start = property_open + 1 + getters[0].start()
    getter_open = property_open + 1 + getters[0].end() - 1
    getter_end = _matching_brace(masked, getter_open)
    _need(getter_end < property_end, f"{class_name}.wrappedValue getter escapes its property")
    return source[getter_start:getter_end + 1]


def _verify_getters(source, replacements):
    extracted = []
    for (name, marker, old_text, new_text), class_name in zip(replacements, ("ParameterInfo", "ModuleInfo")):
        body = _extract_getter(source, class_name)
        normalized = "\n".join(line.strip() for line in body.splitlines())
        _need(normalized.count(new_text) == 1,
              f"{class_name} getter does not contain its unique approved replacement")
        _need(old_text not in normalized,
              f"{class_name} getter still contains the old optional cast")
        _need(normalized.splitlines().count(f"return {name}") == 1
              and normalized.splitlines().count(f"return {name}!") == 1,
              f"{class_name} getter return or force-unwrap fallback changed")
        extracted.append((marker, body))
    return extracted


def _ensure_directory(value, label):
    path = Path(value).expanduser()
    _need(not path.exists() or not path.is_symlink(), f"{label} directory must not be a symlink")
    try:
        path.mkdir(parents=True, exist_ok=True)
    except OSError as error:
        raise HarnessError(f"{label} directory is unavailable") from error
    _need(path.is_dir() and not path.is_symlink(), f"{label} path is not a safe directory")
    return path.resolve()


def _write_atomic(path, data):
    fd, temporary = tempfile.mkstemp(prefix=".mlx-getter-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def _write_log(path, lines):
    _write_atomic(path, ("\n".join(lines).rstrip("\n") + "\n").encode("utf-8"))


def _require_host():
    if platform.system() != "Darwin" or platform.machine().lower() not in {"arm64", "aarch64"}:
        raise HarnessError("requires Darwin arm64")
    env = os.environ
    if (env.get("GITHUB_ACTIONS", "").lower() != "true"
            or env.get("RUNNER_ENVIRONMENT", "").lower() != "github-hosted"
            or env.get("RUNNER_OS", "").lower() != "macos"
            or env.get("RUNNER_ARCH", "").lower() != "arm64"):
        raise HarnessError("requires a hosted GitHub Actions macOS arm64 runner")


def _record_process(lines, label, result):
    lines.extend((f"{label}_returncode={result.returncode}",
                  f"{label}_stdout={json.dumps(result.stdout or '', ensure_ascii=False)}",
                  f"{label}_stderr={json.dumps(result.stderr or '', ensure_ascii=False)}"))


def _capture(argv, label, lines, timeout):
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, check=False)
    except (OSError, subprocess.SubprocessError) as error:
        lines.append(f"{label}_launch_error={json.dumps(str(error), ensure_ascii=False)}")
        raise HarnessError(f"{label} subprocess could not run") from error
    _record_process(lines, label, result)
    return result


def _run(argv, description, lines, label, *, timeout):
    result = _capture(argv, label, lines, timeout)
    if result.returncode != 0:
        raise HarnessError(f"{description} failed with exit status {result.returncode}")
    return result


def _expect_trap(binary, mode, lines, label):
    argv = [str(binary), mode]
    lines.append(f"{label}_argv=" + json.dumps(argv, separators=(",", ":")))
    result = _capture(argv, label, lines, 20)
    combined = (result.stdout or "") + (result.stderr or "")
    marker = f"GETTER_TRAP_MODE:{mode[2:]}"
    _need(result.returncode in {-signal.SIGILL, -signal.SIGTRAP}
          and marker in (result.stderr or "").splitlines()
          and MATRIX_SENTINEL not in combined
          and "MISSING_VALUE_RETURNED" not in combined and "NEGATIVE_CONTROL_RETURNED" not in combined,
          f"{label} did not produce the expected Darwin fatal trap")


def run(args):
    output_dir = _ensure_directory(args.output_dir, "output")
    log_path = output_dir / LOG_NAME
    if log_path.is_symlink():
        log_path.unlink()
    elif log_path.exists():
        _need(log_path.is_file(), "output log path is not a regular file")
        log_path.unlink()
    lines = ["MLX getter compatibility harness", "scope=extracted getters in synthetic generic wrappers only"]
    try:
        _require_host()
        source_root = Path(args.source_root).expanduser().resolve(strict=True)
        _need(source_root.is_dir(), "source root is not a directory")
        work_dir = _ensure_directory(args.work_dir, "work")
        _need(work_dir != output_dir, "output and work directories must be different")
        approved = _approved_patch(source_root)
        module_path = _safe_relative(source_root, f"{MODULE_CHECKOUT}/{MODULE_PATH}")
        source_bytes = _read_regular(module_path)
        source_hash = _sha256(source_bytes)
        _need(len(source_bytes) == EXPECTED_PATCHED_SIZE and source_hash == EXPECTED_PATCHED_SHA256,
              "patched Module.swift size or SHA-256 does not match the approved source")
        source = source_bytes.decode("utf-8")
        getters = _verify_getters(source, approved)
        fixture_path = _safe_relative(source_root, FIXTURE_PATH)
        fixture_bytes = _read_regular(fixture_path)
        _need(len(fixture_bytes) <= 16384, "Swift fixture exceeds the 16 KiB limit")
        generated = fixture_bytes.decode("utf-8")
        for marker, body in getters:
            _need(generated.count(marker) == 1, "Swift fixture getter marker is missing or ambiguous")
            generated = generated.replace(marker, body, 1)
        generated_bytes = generated.encode("utf-8")
        generated_path = work_dir / GENERATED_NAME
        binary_path = work_dir / BINARY_NAME
        if binary_path.is_symlink():
            binary_path.unlink()
        elif binary_path.exists():
            _need(binary_path.is_file(), "harness executable path is not a regular file")
            binary_path.unlink()
        _write_atomic(generated_path, generated_bytes)
        compile_argv = ["swiftc", "-parse-as-library", "-swift-version", "6", "-warnings-as-errors", "-O",
                        str(generated_path), "-o", str(binary_path)]
        lines.extend((f"source_sha256={source_hash}",
                      f"generated_source_sha256={_sha256(generated_bytes)}",
                      "compile_argv=" + json.dumps(compile_argv, separators=(",", ":"))))
        _run(compile_argv, "Swift 6 getter harness compilation", lines, "compile", timeout=180)
        matrix_argv = [str(binary_path)]
        lines.append("matrix_argv=" + json.dumps(matrix_argv, separators=(",", ":")))
        matrix = _run(matrix_argv, "getter behavior matrix", lines, "matrix", timeout=20)
        _need(matrix.stdout == MATRIX_SENTINEL + "\n" and "REFERENCE_MATRIX:" in matrix.stderr,
              "getter matrix output or reference diagnostics are invalid")
        _expect_trap(binary_path, "--missing-parameter", lines, "parameter_missing_value")
        _expect_trap(binary_path, "--missing-module", lines, "module_missing_value")
        _expect_trap(binary_path, "--negative-control-parameter", lines, "parameter_negative_control")
        _expect_trap(binary_path, "--negative-control-module", lines, "module_negative_control")
        _expect_trap(binary_path, "--missing-reference", lines, "reference_missing_value")
        lines.append("The harness is not an MLX/Metal module acceptance test.")
        lines.append(SUCCESS_MARKER)
        _write_log(log_path, lines)
        return log_path
    except Exception as error:
        lines.append(f"FAIL: {error if isinstance(error, HarnessError) else 'unexpected harness error'}")
        _write_log(log_path, lines)
        if isinstance(error, HarnessError):
            raise
        raise HarnessError("unexpected harness error") from error


def main(argv=None):
    parser = argparse.ArgumentParser(description="Compile and run the approved MLX getter compatibility harness")
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--work-dir", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        log_path = run(args)
    except HarnessError as error:
        print(f"MLX getter compatibility failed: {error}", file=sys.stderr)
        return 1
    sys.stdout.write(log_path.read_text(encoding="utf-8"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
