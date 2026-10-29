import ast
import re
import subprocess


PATCH_HELPER = "scripts/patch-argument-parser.py"
PATCH_SCOPE = (
    ("Sources/ArgumentParser/Parsable Types/ParsableArguments.swift",
     '@available(*, deprecated, message: "Use _errorPrefix instead.")'),
    ("Sources/ArgumentParserToolInfo/ToolInfo.swift",
     '@available(*, deprecated, message: "Use custom instead.")'),
)
PATCH_FIELDS = {"path", "originalSHA256", "patchedSHA256", "originalSize", "patchedSize", "removedAnnotation"}


def _need(condition):
    if not condition:
        raise ValueError("invalid committed CI approval")


def _sha256(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def committed_literal(root, commit, path, name):
    try:
        source = subprocess.check_output(["git", "-C", str(root), "show", f"{commit}:{path}"], text=True)
        tree = ast.parse(source)
    except (OSError, subprocess.SubprocessError, SyntaxError) as error:
        raise ValueError("committed CI approval is unavailable") from error
    values = [node.value for node in tree.body if isinstance(node, ast.Assign) and len(node.targets) == 1
              and isinstance(node.targets[0], ast.Name) and node.targets[0].id == name]
    _need(len(values) == 1)
    try:
        return ast.literal_eval(values[0])
    except (ValueError, TypeError, SyntaxError) as error:
        raise ValueError("committed CI approval is not literal data") from error


def approved_patch(root, commit):
    value = committed_literal(root, commit, PATCH_HELPER, "APPROVED_PATCH")
    _need(
        isinstance(value, dict)
        and set(value) == {"schemaVersion", "identity", "version", "url", "revision", "license", "files"}
        and type(value.get("schemaVersion")) is int and value["schemaVersion"] == 1
        and (value.get("identity"), value.get("version"), value.get("url"), value.get("revision")) ==
        ("swift-argument-parser", "1.8.2", "https://github.com/apple/swift-argument-parser",
         "6a52f3251125d74daf04fcbd5e6f08a75d074382")
    )
    license_record, files = value["license"], value["files"]
    _need(isinstance(license_record, dict) and set(license_record) == {"path", "sha256"}
          and license_record.get("path") == "LICENSE.txt" and _sha256(license_record.get("sha256"))
          and isinstance(files, list) and len(files) == len(PATCH_SCOPE))
    _need(all(
        isinstance(item, dict) and set(item) == PATCH_FIELDS and item["path"] == path
        and item["removedAnnotation"] == annotation and _sha256(item["originalSHA256"])
        and _sha256(item["patchedSHA256"]) and type(item["originalSize"]) is int and item["originalSize"] >= 0
        and type(item["patchedSize"]) is int and item["patchedSize"] >= 0
        for item, (path, annotation) in zip(files, PATCH_SCOPE)
    ))
    return value
