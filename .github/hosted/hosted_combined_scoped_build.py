#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import plistlib
import re
import select
import shlex
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

SOURCE_COMMIT = "535b7f85720b2e53c60604e8b7c8abfb4e97ca4b"
SOURCE_TREE = "711a36772737488bb99ffd3a00cbce277be68a68"
WORKFLOW_PATH = ".github/workflows/verify.yml"
HELPER_PATH = ".github/hosted/hosted_combined_scoped_build.py"
PACKAGE_RESOLVED_SHA256 = "b50c36095657623b7356533963726cec44dc55c3ba429f81e2c25b9a0beb823b"
INITIAL_FLOOR = 16 * 1024**3
RUNTIME_FLOOR = 12 * 1024**3
RESOLVE_DEADLINE = 15 * 60
BUILD_DEADLINE = 50 * 60
RETENTION_DEADLINE = 5 * 60
TOTAL_BUDGET = 80 * 60
CLOSURE_DEADLINE = 90
CLEANUP_GRACE = 5
REAP_TIMEOUT = 10
READER_JOIN_TIMEOUT = 15
PROCESS_INTERVAL = 1.0
RESOURCE_INTERVAL = 10.0
MAX_OBSERVATION_GAP = 15.0
MAX_PHASE_OUTPUT_BYTES = 32 * 1024 * 1024
MAX_TABLE_BYTES = 2 * 1024 * 1024
MAX_TABLE_ROWS = 8192
MAX_METADATA_BYTES = 4 * 1024 * 1024
SOURCE_FILE_SHA256 = {
    "Package.swift": "aac35a45d88788b99b52f2dfe4415de7d86fcd97011ef4387ef5bc99d00c144b",
    "Package.resolved": "b50c36095657623b7356533963726cec44dc55c3ba429f81e2c25b9a0beb823b",
    "pill-kit/native/Package.swift": "5ff8c911e743c85e621de4d76069db72f33c5bc033ece03344f6c96f86a1ea40",
    "pill-kit/native/Package.resolved": "733d05f3ba62f3c787baca943cf4d9a8d4dd1cc4d48b798fe93b7224421f975e",
    "scripts/build-app.sh": "995e7724b86601037e70a9b02307cb1a84b3813a6389dbe8d88c874f17b03a15",
    "scripts/package_local_candidate.py": "c89649c340326f90b02532ec1f61a7b9d4639b5a40fca35f77c96529a20e9955",
    "scripts/retain_ci_test_app.py": "32003a812fb174eeee524b992f2061618cab371e97ffd85a2875ba3f4beaf5c8",
    "Resources/GenerateIcon.swift": "768d217afc40db2b93e1a7d9532018952829c699741879cf4e4bc3b0a67a7736",
    "Resources/Info.plist": "3b4c9ba13fd27c2b352cedd2d38910607a412031f5d895182d0c765cca7b798e",
    "LICENSE": "8d054ce0566381aa92ceb8b113c42376602237876b42dfa2e58e6675b35ecf72",
    "Resources/THIRD_PARTY_NOTICES.md": "41b2e85a7162194bb55af3d71fb2e35816aa9c9f757ab1db443d519e6915708b",
    "pill-kit/THIRD_PARTY_NOTICES.md": "ca26e06d2fef497c3ff6d50664b9601d7911fa69d19b28b4c82345ebcda608cb",
    "pill-kit/upstream/LICENSE": "8bc26817d6b5c323f8cb5e5da77182fe0db8a5ad0e0b563903f9382bba06dc9a",
    "Vendor/EventSource/LICENSE.md": "2f9b695627d569a3ce452b2c03fdd34310df78c8ea94edfafd9ce38381e5b502",
    "Vendor/EventSource/PROVENANCE.md": "c92003a775c257ec9a8ba7631d9c5ae464a5f8d68e1912813aa6faf8292eda79",
    "Sources/ImrseApp/Resources/Brand/imrse-menubar-template.pdf": "ae3ee8c9102fe835c9c7d25122ec20cf0ab9f9333a156b65767e298f6df16747",
    "Sources/ImrseLocal/Resources/Qwen3-APACHE-LICENSE.txt": "832dd9e00a68dd83b3c3fb9f5588dad7dcf337a0db50f7d9483f310cd292e92e",
}
PINS = {
    "eventsource": ("1.5.1", "86b5096ac59ab46e66bd1f6377c604bc1dab0bc2"),
    "lottie-ios": ("4.6.1", "f4db77d7feacba0c2360b84a40c38a6ce8ff399d"),
    "mlx-swift": ("0.31.6", "0bb916c67f4b9e5c682cbe02a42c701c93ab5021"),
    "mlx-swift-lm": ("3.31.4", "bd4b7434e6bdb588c7ef55706ff8904cb7fd4c57"),
    "swift-argument-parser": ("1.8.2", "6a52f3251125d74daf04fcbd5e6f08a75d074382"),
    "swift-asn1": ("1.7.3", "3b6410f7dee09eb33cdd26260c5fd47fda19b0e2"),
    "swift-collections": ("1.7.1", "98ef3c98609a1e31b7e157b5b619579001a789d6"),
    "swift-crypto": ("4.5.2", "da9d28d69ebe3894b18376c8f2395c2f37b8448f"),
    "swift-huggingface": ("0.9.0", "b721959445b617d0bf03910b2b4aced345fd93bf"),
    "swift-jinja": ("2.5.1", "4588064a20f3fc093c95f2f7d3359999bf30cae5"),
    "swift-numerics": ("1.1.1", "0c0290ff6b24942dadb83a929ffaaa1481df04a2"),
    "swift-syntax": ("603.0.2", "79e4b74a295b6eb74a8b585e3a39d29e70c1dbd1"),
    "swift-transformers": ("1.3.0", "b38443e44d93eca770f2eb68e2a4d0fa100f9aa2"),
    "yyjson": ("0.12.0", "8b4a38dc994a110abaec8a400615567bd996105f"),
}
NESTED = {
    "Source/Cmlx/mlx": ("ce45c52505c8158ea48d2a54e8caae05efd86bfe", "505098ad0928f591b9f97a9c1ff2564d72018ab3", "https://github.com/ml-explore/mlx"),
    "Source/Cmlx/mlx-c": ("0726ca922fc902c4c61ef9c27d94132be418e945", "cb2850ec1d621c9e4135da7bd8624b40500b3339", "https://github.com/ml-explore/mlx-c"),
}
LSTART_PATTERN = re.compile(r"^\w{3}\s+\w{3}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}\s+\d{4}$")
DISK_DEVICE_PATTERN = re.compile(r"/dev/disk[0-9]+(?:s[0-9]+)*")
APFS_CONTAINER_PATTERN = re.compile(r"disk[0-9]+")


class ScopeError(Exception):
    pass


class LifetimeError(ScopeError):
    pass


_TOTAL_DEADLINE = None
_UNRESOLVED_PROCESSES = []


def remaining_budget(deadline, clock=None):
    remaining = deadline - (clock or time.monotonic)()
    if remaining <= 0:
        raise ScopeError("deadline-exhausted")
    return remaining


def require_process_lifetime_support():
    if signal.getsignal(signal.SIGCHLD) is not signal.SIG_DFL:
        raise LifetimeError("sigchld-handler")
    if not callable(getattr(select, "kqueue", None)) or getattr(select, "kevent", None) is None:
        raise LifetimeError("kqueue-unavailable")
    for name in ("KQ_FILTER_PROC", "KQ_NOTE_EXIT", "KQ_EV_ADD", "KQ_EV_ENABLE"):
        if getattr(select, name, None) is None:
            raise LifetimeError("kqueue-constant:" + name)


class RetainedProcess:
    def __init__(self, child, watcher, pid):
        self.child = child
        self.watcher = watcher
        self.pid = pid
        self.exited = False
        self.exit_data = None
        self.authority = True
        self.reaped = False
        self.signals = []

    @classmethod
    def spawn(cls, argv, environment, cwd, deadline=None, merge_stderr=False):
        require_process_lifetime_support()
        if deadline is None:
            deadline = time.monotonic() + REAP_TIMEOUT
        remaining_budget(deadline)
        try:
            child = subprocess.Popen(argv, cwd=cwd, env=environment, stdout=subprocess.PIPE, stderr=subprocess.STDOUT if merge_stderr else subprocess.PIPE, start_new_session=True)
        except OSError as error:
            raise LifetimeError("spawn") from error
        instance = cls(child, None, child.pid)
        _UNRESOLVED_PROCESSES.append(instance)
        try:
            remaining_budget(deadline)
            watcher = select.kqueue()
            instance.watcher = watcher
            event = select.kevent(child.pid, filter=select.KQ_FILTER_PROC, flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE, fflags=select.KQ_NOTE_EXIT)
            registered = watcher.control([event], 1, 0)
            if registered:
                cls._validate_exit(registered, child.pid)
        except BaseException as error:
            failures = []
            try:
                remaining_budget(deadline)
                instance.signal_group(signal.SIGKILL)
            except Exception as cleanup_error:
                failures.append("signal:" + type(cleanup_error).__name__)
            try:
                instance.retire_and_reap(remaining_budget(deadline))
            except Exception as cleanup_error:
                failures.append("reap:" + type(cleanup_error).__name__)
            instance.close()
            if isinstance(error, (KeyboardInterrupt, SystemExit)):
                if failures:
                    error.args = (*error.args, "cleanup-incomplete:" + ",".join(failures))
                raise
            raise LifetimeError("watch-setup" + (";cleanup:" + ",".join(failures) if failures else "")) from error
        if registered:
            instance.exited = True
            instance.exit_data = registered[0].data
        return instance

    @staticmethod
    def _validate_exit(events, pid):
        if len(events) != 1:
            raise LifetimeError("kqueue-event-count")
        event = events[0]
        if event.ident != pid or event.filter != select.KQ_FILTER_PROC or not (event.fflags & select.KQ_NOTE_EXIT) or getattr(event, "flags", 0) & getattr(select, "KQ_EV_ERROR", 0):
            raise LifetimeError("kqueue-event-identity")

    def wait_exit(self, timeout):
        if self.exited:
            return True
        try:
            events = self.watcher.control(None, 1, max(0.0, timeout))
        except OSError as error:
            raise LifetimeError("kqueue-wait") from error
        if not events:
            return False
        self._validate_exit(events, self.pid)
        self.exited = True
        self.exit_data = events[0].data
        return True

    def signal_group(self, signum):
        if not self.authority or self.reaped or self.child.returncode is not None:
            raise LifetimeError("signal-authority")
        try:
            os.killpg(self.pid, signum)
        except ProcessLookupError:
            return
        except PermissionError as error:
            raise LifetimeError("signal-permission") from error
        self.signals.append(signum)

    def retire_and_reap(self, timeout):
        if self.reaped:
            return self.child.returncode
        if not self.authority:
            raise LifetimeError("reap-already-attempted")
        self.authority = False
        try:
            code = self.child.wait(timeout=max(0.0, timeout))
        except subprocess.TimeoutExpired as error:
            raise LifetimeError("reap-timeout") from error
        self.reaped = True
        if self in _UNRESOLVED_PROCESSES:
            _UNRESOLVED_PROCESSES.remove(self)
        return code

    def close(self):
        try:
            self.watcher.close()
        except Exception:
            pass

    def group_absent(self):
        if not self.reaped or self.authority:
            raise LifetimeError("group-probe-before-retirement")
        try:
            os.killpg(self.pid, 0)
        except ProcessLookupError:
            return True
        except OSError as error:
            raise LifetimeError("group-absence-unproved") from error
        return False


class ProcessTableError(ScopeError):
    pass


class IdentityError(ScopeError):
    pass


class ResourceError(ScopeError):
    pass


@dataclass(frozen=True, order=True)
class Identity:
    pid: int
    start: str


@dataclass(frozen=True)
class ProcessRow:
    pid: int
    ppid: int
    pgid: int
    start: str
    comm: str


@dataclass
class ProcessTable:
    rows: list


@dataclass
class OwnedState:
    tracked: set
    lineage: set
    escapes: set
    reparented: set
    parents: dict


@dataclass
class ReaderSummary:
    joined: bool
    total: int
    truncated: bool
    error: str


@dataclass
class PhaseResult:
    name: str
    argv: list
    exitCode: object
    primaryFailure: object
    cleanupFailures: list
    resourceViolations: list
    closure: dict
    outputBytes: int
    outputTruncated: bool
    startedAt: float
    finishedAt: float
    rootIdentity: object
    resourceSamples: int
    firstResource: dict
    lastResource: dict
    groupEscapes: list
    reparented: list

    def ok(self):
        return (
            self.primaryFailure is None
            and not self.cleanupFailures
            and not self.resourceViolations
            and isinstance(self.closure, dict)
            and self.closure.get("complete") is True
            and not self.closure.get("escapes")
        )

    def to_dict(self):
        return {
            "name": self.name,
            "argv": self.argv,
            "exitCode": self.exitCode,
            "primaryFailure": self.primaryFailure,
            "cleanupFailures": self.cleanupFailures,
            "resourceViolations": self.resourceViolations,
            "closure": self.closure,
            "outputBytes": self.outputBytes,
            "outputTruncated": self.outputTruncated,
            "startedAt": self.startedAt,
            "finishedAt": self.finishedAt,
            "rootIdentity": self.rootIdentity,
            "resourceSamples": self.resourceSamples,
            "firstResource": self.firstResource,
            "lastResource": self.lastResource,
            "groupEscapes": self.groupEscapes,
            "reparented": self.reparented,
        }


def sha256_bytes(payload):
    return hashlib.sha256(payload).hexdigest()


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def parse_process_table(text, max_bytes=MAX_TABLE_BYTES, max_rows=MAX_TABLE_ROWS):
    if len(text.encode("utf-8")) > max_bytes:
        raise ProcessTableError("process-table-oversize")
    rows = []
    seen = set()
    for line in text.splitlines():
        if not line.strip():
            continue
        tokens = line.split()
        if len(tokens) < 8:
            raise ProcessTableError("process-table-malformed")
        try:
            pid = int(tokens[0])
            ppid = int(tokens[1])
            pgid = int(tokens[2])
        except ValueError as error:
            raise ProcessTableError("process-table-malformed") from error
        start = " ".join(tokens[3:8])
        comm = " ".join(tokens[8:]) if len(tokens) > 8 else ""
        if not LSTART_PATTERN.match(start):
            raise ProcessTableError("process-table-start-format")
        if pid in seen:
            raise ProcessTableError("process-table-duplicate-pid")
        seen.add(pid)
        rows.append(ProcessRow(pid, ppid, pgid, start, comm))
        if len(rows) > max_rows:
            raise ProcessTableError("process-table-row-limit")
    return ProcessTable(rows)


def discover_owned(table, root, tracked, root_pgid, known_parents):
    present = {Identity(row.pid, row.start): row for row in table.rows}
    children = {}
    for row in table.rows:
        children.setdefault(row.ppid, []).append(row)
    frontier = [row for identity, row in present.items() if identity == root or identity in tracked]
    lineage = set()
    while frontier:
        row = frontier.pop()
        identity = Identity(row.pid, row.start)
        if identity in lineage:
            continue
        lineage.add(identity)
        for child in children.get(row.pid, []):
            child_identity = Identity(child.pid, child.start)
            if child_identity not in lineage:
                frontier.append(child)
    cumulative = set(tracked) | lineage
    escapes = {identity for identity in lineage if present[identity].pgid != root_pgid}
    reparented = set()
    parents = dict(known_parents)
    for identity in lineage:
        row = present[identity]
        if identity in known_parents and known_parents[identity] != row.ppid:
            reparented.add(identity)
        parents.setdefault(identity, row.ppid)
    return OwnedState(tracked=cumulative, lineage=lineage, escapes=escapes, reparented=reparented, parents=parents)


def evaluate_resources(sample, floor):
    issues = []
    if not sample.get("complete"):
        issues.append("resources-incomplete:" + str(sample.get("reason", "")))
        return issues
    filesystem = sample.get("filesystemAvailableBytes")
    apfs = sample.get("actualAPFSFreeBytes")
    if not isinstance(filesystem, int) or not isinstance(apfs, int):
        issues.append("resources-incomplete:disk")
    elif min(filesystem, apfs) < floor:
        issues.append("disk-floor")
    if sample.get("memoryPressure") != "1":
        issues.append("memory-pressure")
    if sample.get("swapUsedBytes") != 0:
        issues.append("zero-swap")
    return issues


def evaluate_pins(lock_payload):
    try:
        pins = {item["identity"]: (item["state"]["version"], item["state"]["revision"]) for item in lock_payload["pins"]}
    except (KeyError, TypeError) as error:
        raise ScopeError("package-resolved-shape") from error
    if pins != PINS:
        raise ScopeError("package-pins-mismatch")
    return pins


def evaluate_checkouts(pins, checkout_heads, missing):
    issues = []
    unexpected = set(checkout_heads) - set(pins)
    if unexpected:
        issues.append("checkouts-unexpected:" + ",".join(sorted(unexpected)))
    missing = set(missing)
    if not missing.issubset({"eventsource"}):
        issues.append("checkouts-missing:" + ",".join(sorted(missing)))
    for identity, head in checkout_heads.items():
        if identity in pins and head != pins[identity][1]:
            issues.append("checkout-revision:" + identity)
    return issues


def evaluate_eventsource(missing, package_swift_text, provenance_text):
    if "eventsource" not in set(missing):
        return []
    issues = []
    if '.package(path: "Vendor/EventSource")' not in package_swift_text:
        issues.append("eventsource-local-override")
    if PINS["eventsource"][1] not in provenance_text:
        issues.append("eventsource-provenance")
    return issues


def parse_gitmodules(text):
    modules = {}
    current = None
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if line.startswith("[submodule ") and line.endswith("]"):
            current = {}
        elif current is not None and "=" in line:
            key, value = line.split("=", 1)
            current[key.strip()] = value.strip().strip('"')
        if current is not None and "path" in current and "url" in current:
            modules[current["path"]] = current["url"]
            current = None
    return modules


def evaluate_submodules(module_sets, nested_heads, nested_trees):
    issues = []
    if set(module_sets.get("mlx-swift", {})) != set(NESTED):
        issues.append("mlx-submodules-mismatch")
    for identity, modules in module_sets.items():
        if identity != "mlx-swift" and modules:
            issues.append("unexpected-submodules:" + identity)
    for relative, (commit, tree, url) in NESTED.items():
        head = nested_heads.get(relative)
        tree_actual = nested_trees.get(relative)
        if head != commit:
            issues.append("nested-commit:" + relative)
        if tree_actual != tree:
            issues.append("nested-tree:" + relative)
        if module_sets.get("mlx-swift", {}).get(relative) != url:
            issues.append("nested-url:" + relative)
    return issues


def evaluate_toolchain(observations):
    issues = []
    if observations.get("uname") != "Darwin arm64":
        issues.append("darwin-arm64")
    os_major = observations.get("osVersion", "").split(".")[0]
    if not os_major.isdigit() or int(os_major) < 27:
        issues.append("macos-27")
    xcode_match = re.search(r"^Xcode (\d+)", observations.get("xcode", ""), re.MULTILINE)
    if not xcode_match or int(xcode_match.group(1)) < 27:
        issues.append("xcode-27")
    swift_match = re.search(r"Swift version (\d+)\.(\d+)", observations.get("swift", ""))
    if not swift_match or int(swift_match.group(1)) != 6 or int(swift_match.group(2)) < 4:
        issues.append("swift-6.4")
    sdk_major = observations.get("sdkVersion", "").split(".")[0]
    if not sdk_major.isdigit() or int(sdk_major) < 27:
        issues.append("sdk-27")
    if observations.get("metalExitCode") != 0:
        issues.append("metal")
    if "swiftbuild" not in observations.get("buildHelp", ""):
        issues.append("swiftbuild")
    for flag in ("--only-use-versions-from-resolved-file", "--jobs", "--disable-experimental-prebuilts", "--skip-update"):
        if flag not in observations.get("buildHelp", ""):
            issues.append("build-flag:" + flag)
    if "--disable-automatic-resolution" not in observations.get("resolveHelp", ""):
        issues.append("resolve-flag")
    if observations.get("realSwift", "") and not observations["realSwift"].startswith("/"):
        issues.append("swift-executable")
    return issues


class _CappedReader:
    def __init__(self, stream, state):
        self.stream = stream
        self.state = state
        self.data = bytearray()
        self.error = None
        self.thread = threading.Thread(target=self._run, name="metadata-output", daemon=True)

    def start(self):
        self.thread.start()
        return self

    def _run(self):
        try:
            while True:
                chunk = self.stream.read(65536)
                if not chunk:
                    break
                with self.state["lock"]:
                    remaining = self.state["limit"] - self.state["total"]
                    if remaining > 0:
                        self.data.extend(chunk[:remaining])
                    self.state["total"] += len(chunk)
                    if self.state["total"] > self.state["limit"]:
                        self.state["oversize"] = True
        except Exception as error:
            self.error = type(error).__name__ + ": " + str(error)

    def join(self, timeout):
        self.thread.join(timeout)
        return not self.thread.is_alive()


def run_bounded(argv, environment, timeout, max_bytes=MAX_METADATA_BYTES, cwd=None, deadline=None):
    started = time.monotonic()
    deadline = min(started + timeout, deadline if deadline is not None else float("inf"), _TOTAL_DEADLINE if _TOTAL_DEADLINE is not None else float("inf"))
    reserve = min(REAP_TIMEOUT, remaining_budget(deadline) / 2)
    work_deadline = deadline - reserve
    state = {"lock": threading.Lock(), "total": 0, "limit": max_bytes, "oversize": False}
    proc = None
    readers = []
    primary = None
    failures = []
    code = None
    try:
        proc = RetainedProcess.spawn(argv, environment, cwd, deadline=deadline)
        for stream in (proc.child.stdout, proc.child.stderr):
            reader = _CappedReader(stream, state)
            readers.append(reader)
            reader.start()
        while True:
            now = time.monotonic()
            if state["oversize"]:
                raise ScopeError("metadata-output-oversize:" + argv[0])
            if now >= work_deadline:
                raise ScopeError("metadata-timeout:" + argv[0])
            if proc.wait_exit(0):
                if not any(reader.thread.is_alive() for reader in readers):
                    break
            time.sleep(min(0.01, remaining_budget(work_deadline)))
    except BaseException as error:
        primary = error
    finally:
        if proc is not None:
            try:
                remaining_budget(deadline)
                if proc.authority:
                    proc.signal_group(signal.SIGKILL)
            except Exception as error:
                failures.append("signal:" + type(error).__name__)
            try:
                code = proc.retire_and_reap(remaining_budget(deadline))
            except Exception as error:
                failures.append("reap:" + type(error).__name__)
            proc.close()
        for reader in readers:
            try:
                if not reader.join(remaining_budget(deadline)):
                    failures.append("reader-unjoined")
                    continue
                if reader.error:
                    failures.append("reader-error:" + reader.error)
                reader.stream.close()
            except Exception as error:
                failures.append("reader:" + type(error).__name__)
        if proc is not None and proc.reaped:
            try:
                remaining_budget(deadline)
                if not proc.group_absent():
                    raise LifetimeError("group-present-after-retirement")
                remaining_budget(deadline)
            except Exception as error:
                failures.append("group-absence:" + type(error).__name__ + ":" + str(error))
        if time.monotonic() > deadline:
            failures.append("metadata-deadline")
    if state["oversize"] or state["total"] > max_bytes or sum(len(reader.data) for reader in readers) > max_bytes:
        if primary is None:
            primary = ScopeError("metadata-output-oversize:" + argv[0])
    if primary is not None:
        if failures:
            primary.args = (*primary.args, "cleanup-incomplete:" + ",".join(failures))
        raise primary
    if failures or proc is None or not proc.reaped:
        raise ScopeError("metadata-incomplete:" + ",".join(failures))
    return subprocess.CompletedProcess(argv, code, bytes(readers[0].data), bytes(readers[1].data))


def run_git(repository, arguments, environment, timeout=30):
    completed = run_bounded(["/usr/bin/git", "-c", "core.fsmonitor=false", "-C", str(repository), *arguments], environment, timeout)
    if completed.returncode != 0:
        raise ScopeError("git-failed:" + arguments[0])
    return completed.stdout.decode("utf-8", errors="replace").strip()


def check_source(source, expected_commit, expected_tree, environment):
    if source.is_symlink() or not source.is_dir():
        raise ScopeError("source-directory")
    toplevel = run_git(source, ("rev-parse", "--show-toplevel"), environment)
    if Path(toplevel).resolve() != source.resolve():
        raise ScopeError("source-not-worktree-root")
    head = run_git(source, ("rev-parse", "HEAD"), environment)
    tree = run_git(source, ("rev-parse", "HEAD^{tree}"), environment)
    status = run_git(source, ("status", "--porcelain=v1", "--untracked-files=all"), environment)
    if head != expected_commit or tree != expected_tree:
        raise ScopeError("source-identity")
    if status:
        raise ScopeError("source-dirty")
    files = {}
    for relative, expected in SOURCE_FILE_SHA256.items():
        path = source / relative
        if path.is_symlink() or not path.is_file() or sha256_file(path) != expected:
            raise ScopeError("source-file:" + relative)
        files[relative] = expected
    for relative in (".build", ".swiftpm", "dist"):
        if (source / relative).exists():
            raise ScopeError("source-generated:" + relative)
    return {"commitSHA": head, "treeSHA": tree, "clean": True, "files": files}


def check_control(control, expected_commit, environment):
    if control.is_symlink() or not control.is_dir():
        raise ScopeError("control-directory")
    toplevel = run_git(control, ("rev-parse", "--show-toplevel"), environment)
    if Path(toplevel).resolve() != control.resolve():
        raise ScopeError("control-not-worktree-root")
    head = run_git(control, ("rev-parse", "HEAD"), environment)
    tree = run_git(control, ("rev-parse", "HEAD^{tree}"), environment)
    status = run_git(control, ("status", "--porcelain=v1", "--untracked-files=all"), environment)
    if head != expected_commit:
        raise ScopeError("control-identity")
    if status:
        raise ScopeError("control-dirty")
    workflow = control / WORKFLOW_PATH
    helper = control / HELPER_PATH
    if workflow.is_symlink() or not workflow.is_file():
        raise ScopeError("control-workflow")
    if helper.is_symlink() or not helper.is_file():
        raise ScopeError("control-helper")
    workflow_text = workflow.read_text(encoding="utf-8")
    for marker in ("hosted-combined-build:", "hosted-combined-535b7f8", "runs-on: xcode-27", "timeout-minutes: 90", "actions/checkout@11d5960a326750d5838078e36cf38b85af677262"):
        if marker not in workflow_text:
            raise ScopeError("control-workflow-marker:" + marker)
    job_text = workflow_text.split("hosted-combined-build:", 1)[1]
    for marker in ("runs-on: xcode-27", "timeout-minutes: 90", "inputs.mode == 'hosted-combined-535b7f8'"):
        if marker not in job_text:
            raise ScopeError("control-job-marker:" + marker)
    if job_text.count("actions/upload-artifact@") != 2 or job_text.count("actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02") != 2 or re.findall(r"^\s+retention-days: (\d+)\s*$", job_text, re.MULTILINE) != ["7", "7"]:
        raise ScopeError("control-delivery-policy")
    exporter = control / ".github/hosted/export_hosted_combined.py"
    if exporter.is_symlink() or not exporter.is_file():
        raise ScopeError("control-exporter")
    if job_text.count("actions/checkout@11d5960a326750d5838078e36cf38b85af677262") != 2:
        raise ScopeError("control-workflow-checkout-count")
    return {
        "commitSHA": head,
        "treeSHA": tree,
        "clean": True,
        "workflowSHA256": sha256_file(workflow),
        "helperSHA256": sha256_file(helper),
        "exporterSHA256": sha256_file(exporter),
    }


def runtime_environment(evidence):
    return {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": str(evidence / "home"),
        "TMPDIR": str(evidence / "tmp"),
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONNOUSERSITE": "1",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": str(evidence / "home/gitconfig"),
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_ALLOW_PROTOCOL": "file",
    }


def check_toolchain(environment):
    def require_success(completed, label):
        if completed.returncode != 0:
            raise ScopeError("toolchain-command:" + label)
        return completed

    observations = {}
    uname = require_success(run_bounded(["/usr/bin/uname", "-sm"], environment, 10), "uname")
    observations["uname"] = uname.stdout.decode().strip()
    os_version = require_success(run_bounded(["/usr/bin/sw_vers", "-productVersion"], environment, 10), "sw-vers")
    observations["osVersion"] = os_version.stdout.decode().strip()
    developer = require_success(run_bounded(["/usr/bin/xcode-select", "-p"], environment, 10), "xcode-select")
    observations["developerDirectory"] = developer.stdout.decode().strip()
    tool_environment = dict(environment)
    tool_environment["DEVELOPER_DIR"] = observations["developerDirectory"]
    xcode = require_success(run_bounded(["/usr/bin/xcodebuild", "-version"], tool_environment, 20), "xcodebuild")
    observations["xcode"] = xcode.stdout.decode().strip()
    swift = require_success(run_bounded(["/usr/bin/xcrun", "swift", "--version"], tool_environment, 20), "swift-version")
    observations["swift"] = swift.stdout.decode().strip()
    sdk = require_success(run_bounded(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"], tool_environment, 20), "sdk-version")
    observations["sdkVersion"] = sdk.stdout.decode().strip()
    sdk_path = require_success(run_bounded(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], tool_environment, 20), "sdk-path")
    observations["sdkPath"] = sdk_path.stdout.decode().strip()
    real_swift = require_success(run_bounded(["/usr/bin/xcrun", "--find", "swift"], tool_environment, 20), "find-swift")
    observations["realSwift"] = real_swift.stdout.decode().strip()
    metal = run_bounded(["/usr/bin/xcrun", "--sdk", "macosx", "metal", "--version"], tool_environment, 20)
    observations["metalExitCode"] = metal.returncode
    observations["metalVersion"] = metal.stdout.decode().strip()
    build_help = require_success(run_bounded(["/usr/bin/xcrun", "swift", "build", "--help"], tool_environment, 20), "build-help")
    observations["buildHelp"] = build_help.stdout.decode("utf-8", errors="replace")
    resolve_help = require_success(run_bounded(["/usr/bin/xcrun", "swift", "package", "resolve", "--help"], tool_environment, 20), "resolve-help")
    observations["resolveHelp"] = resolve_help.stdout.decode("utf-8", errors="replace")
    issues = evaluate_toolchain(observations)
    if issues:
        raise ScopeError("toolchain:" + ",".join(issues))
    return observations


class OutputReader:
    def __init__(self, stream, path, limit):
        self.stream = stream
        self.path = path
        self.limit = limit
        self.total = 0
        self.written = 0
        self.truncated = False
        self.error = None
        self.thread = threading.Thread(target=self._run, name="scope-output", daemon=True)

    def start(self):
        self.thread.start()
        return self

    def _run(self):
        try:
            with self.path.open("xb") as sink:
                while True:
                    chunk = self.stream.read(65536)
                    if not chunk:
                        break
                    self.total += len(chunk)
                    if self.written < self.limit:
                        take = chunk[: self.limit - self.written]
                        sink.write(take)
                        self.written += len(take)
                    if self.total > self.limit:
                        self.truncated = True
        except Exception as error:
            self.error = type(error).__name__ + ": " + str(error)
        finally:
            try:
                self.stream.close()
            except Exception:
                pass

    def join(self, timeout):
        self.thread.join(timeout)
        return ReaderSummary(not self.thread.is_alive(), self.total, self.truncated, self.error)

    def close(self):
        try:
            self.stream.close()
        except Exception:
            pass


class SystemPhaseIO:
    def __init__(self, evidence, logs, environment):
        self.evidence = evidence
        self.logs = logs
        self.environment = environment

    def clock(self):
        return time.monotonic()

    def sleep(self, seconds):
        time.sleep(seconds)

    def spawn(self, argv, environment, cwd, deadline=None):
        return RetainedProcess.spawn(argv, environment, cwd, deadline=deadline, merge_stderr=True)

    def identity(self, pid, deadline=None):
        completed = run_bounded(["/bin/ps", "-p", str(pid), "-o", "pid=,lstart="], self.environment, 10, deadline=deadline)
        if completed.returncode != 0:
            raise IdentityError("identity-query")
        line = completed.stdout.decode("utf-8", errors="replace").strip()
        tokens = line.split()
        if len(tokens) < 6:
            raise IdentityError("identity-format")
        try:
            actual_pid = int(tokens[0])
        except ValueError as error:
            raise IdentityError("identity-format") from error
        start = " ".join(tokens[1:6])
        if actual_pid != pid or not LSTART_PATTERN.match(start):
            raise IdentityError("identity-format")
        return Identity(pid, start)

    def process_table(self, deadline=None):
        completed = run_bounded(["/bin/ps", "-A", "-o", "pid=,ppid=,pgid=,lstart=,comm="], self.environment, 10, MAX_TABLE_BYTES, deadline=deadline)
        if completed.returncode != 0:
            raise ProcessTableError("process-table-exit")
        return parse_process_table(completed.stdout.decode("utf-8", errors="replace"))

    def signal_group(self, proc, signum):
        proc.signal_group(signum)

    def retire(self, proc, timeout):
        code = proc.retire_and_reap(timeout)
        proc.close()
        return code

    def abort(self, proc, deadline=None):
        if deadline is None:
            raise LifetimeError("abort-deadline-required")
        if not proc.reaped:
            if proc.authority:
                remaining_budget(deadline)
                proc.signal_group(signal.SIGKILL)
                self.retire(proc, remaining_budget(deadline))
            else:
                raise LifetimeError("unreaped-retired-leader")

    def start_reader(self, child, name):
        return OutputReader(child.stdout, self.logs / (name + ".log"), MAX_PHASE_OUTPUT_BYTES).start()

    def resources(self, deadline=None):
        deadline = min(time.monotonic() + MAX_OBSERVATION_GAP, deadline if deadline is not None else float("inf"), _TOTAL_DEADLINE if _TOTAL_DEADLINE is not None else float("inf"))
        def observe(name, argv, cap):
            try:
                completed = run_bounded(argv, self.environment, min(cap, remaining_budget(deadline)), deadline=deadline)
            except ScopeError as error:
                raise ResourceError("resource-command:" + name + ":" + str(error)) from error
            if completed.returncode != 0:
                raise ResourceError("resource-command:" + name + ":exit:" + str(completed.returncode))
            return completed
        try:
            remaining_budget(deadline)
            statvfs = os.statvfs(self.evidence)
            remaining_budget(deadline)
            filesystem = statvfs.f_bavail * statvfs.f_frsize
            df = observe("df", ["/bin/df", "-P", str(self.evidence)], 10)
            rows = df.stdout.decode("utf-8", errors="replace").splitlines()
            if len(rows) != 2:
                return {"complete": False, "reason": "df-rows"}
            device = rows[1].split()[0]
            if not DISK_DEVICE_PATTERN.fullmatch(device):
                return {"complete": False, "reason": "df-device"}
            info = observe("diskutil-info", ["/usr/sbin/diskutil", "info", "-plist", device], 15)
            info_payload = plistlib.loads(info.stdout)
            container_reference = info_payload.get("APFSContainerReference")
            if not isinstance(container_reference, str) or not APFS_CONTAINER_PATTERN.fullmatch(container_reference):
                return {"complete": False, "reason": "apfs-container-reference"}
            listing = observe("diskutil-apfs", ["/usr/sbin/diskutil", "apfs", "list", "-plist", container_reference], 15)
            listing_payload = plistlib.loads(listing.stdout)
            container = next((item for item in listing_payload.get("Containers", []) if item.get("ContainerReference") == container_reference), None)
            if container is None:
                return {"complete": False, "reason": "apfs-container"}
            apfs_free = container.get("CapacityFree")
            if not isinstance(apfs_free, int):
                return {"complete": False, "reason": "apfs-capacity"}
            pressure = observe("sysctl-pressure", ["/usr/sbin/sysctl", "-n", "kern.memorystatus_vm_pressure_level"], 10)
            swap = observe("sysctl-swap", ["/usr/sbin/sysctl", "-n", "vm.swapusage"], 10)
            remaining_budget(deadline)
            swap_match = re.search(r"used\s*=\s*([0-9.]+)([KMG])", swap.stdout.decode("utf-8", errors="replace"))
            if not swap_match:
                return {"complete": False, "reason": "swap-format"}
            swap_used = float(swap_match.group(1)) * {"K": 1024, "M": 1024**2, "G": 1024**3}[swap_match.group(2)]
            return {
                "complete": True,
                "filesystemAvailableBytes": filesystem,
                "actualAPFSFreeBytes": apfs_free,
                "filesystemDevice": device,
                "containerReference": container_reference,
                "containerUUID": container.get("APFSContainerUUID"),
                "memoryPressure": pressure.stdout.decode().strip(),
                "swapUsedBytes": swap_used,
            }
        except Exception as error:
            return {"complete": False, "reason": type(error).__name__ + ": " + str(error)}


def cleanup_phase(io, proc, root, tracked, root_pgid, known_parents, deadline, observed_escapes=None):
    failures = []
    group_signals = []
    escapes = set(observed_escapes or ())
    tracked = set(tracked)
    known_parents = dict(known_parents)
    last_table = None
    last_remaining = []
    last_group = []
    post_reap_observed = False

    def observe():
        nonlocal tracked, known_parents, last_table, escapes, last_remaining, last_group
        table = io.process_table(deadline=deadline)
        state = discover_owned(table, root, tracked, root_pgid, known_parents)
        tracked = state.tracked
        known_parents = state.parents
        escapes |= state.escapes
        last_table = table
        remaining_budget(deadline, io.clock)
        last_remaining = [identity for identity in state.lineage if proc.reaped or identity != root]
        last_group = [Identity(row.pid, row.start) for row in table.rows if row.pgid == root_pgid and (proc.reaped or Identity(row.pid, row.start) != root)]
        return state

    def finish(reason=None):
        complete = proc.reaped and post_reap_observed and io.clock() < deadline and not last_remaining and not last_group and not escapes and not failures
        return {
            "complete": complete,
            "observedOnly": True,
            "remaining": [[identity.pid, identity.start] for identity in last_remaining],
            "groupMembers": [[identity.pid, identity.start] for identity in last_group],
            "escapes": [[identity.pid, identity.start] for identity in sorted(escapes)],
            "rootReaped": proc.reaped,
            "signalAuthorityRetired": not proc.authority,
            "groupSignals": list(group_signals),
            "reason": reason,
            "limitation": "Bounded process-table observation only; an unobserved transient or escaped descendant is not an atomic-discovery claim.",
        }

    if io.clock() >= deadline:
        return finish("closure-deadline"), failures
    try:
        observe()
    except Exception as error:
        failures.append("cleanup-process-table:" + type(error).__name__)
        return finish("cleanup-process-table"), failures
    root_present = any(Identity(row.pid, row.start) == root for row in last_table.rows)
    need_signal = (not proc.exited) or (root_present and (bool(last_remaining) or bool(last_group)))
    if need_signal and io.clock() < deadline:
        try:
            io.signal_group(proc, signal.SIGTERM)
            group_signals.append(signal.SIGTERM)
        except Exception as error:
            failures.append("sigterm:" + type(error).__name__)
        grace = min(io.clock() + CLEANUP_GRACE, deadline)
        while io.clock() < grace:
            try:
                observe()
                proc.wait_exit(0)
            except Exception as error:
                failures.append("cleanup-observe:" + type(error).__name__)
                break
            if proc.exited and not last_remaining and not last_group:
                break
            if escapes and not last_group and proc.exited:
                break
            io.sleep(min(0.2, max(0.0, deadline - io.clock())))
        root_present = any(Identity(row.pid, row.start) == root for row in last_table.rows)
        if io.clock() < deadline and ((not proc.exited) or (root_present and (last_remaining or last_group))):
            try:
                io.signal_group(proc, signal.SIGKILL)
                group_signals.append(signal.SIGKILL)
            except Exception as error:
                failures.append("sigkill:" + type(error).__name__)
            while io.clock() < deadline:
                try:
                    observe()
                    proc.wait_exit(0)
                except Exception as error:
                    failures.append("cleanup-observe:" + type(error).__name__)
                    break
                if proc.exited and not last_remaining and not last_group:
                    break
                if escapes and not last_group and proc.exited:
                    break
                io.sleep(min(0.2, max(0.0, deadline - io.clock())))
    if not proc.exited and io.clock() < deadline:
        try:
            proc.wait_exit(max(0.0, deadline - io.clock()))
        except Exception as error:
            failures.append("exit-observation:" + type(error).__name__)
    try:
        io.retire(proc, remaining_budget(deadline, io.clock))
    except Exception as error:
        failures.append("reap:" + type(error).__name__)
    if proc.reaped and io.clock() < deadline:
        try:
            observe()
            post_reap_observed = True
        except Exception as error:
            failures.append("closure-process-table:" + type(error).__name__)
    return finish(), failures


def run_phase(io, name, argv, environment, cwd, deadline_seconds, resource_floor, total_deadline):
    started = io.clock()
    closure_deadline = min(started + deadline_seconds, total_deadline)
    work_deadline = closure_deadline - CLOSURE_DEADLINE
    primary = None
    cleanup_failures = []
    resource_violations = []
    closure = {"complete": False, "observedOnly": True, "remaining": [], "groupMembers": [], "escapes": [], "rootReaped": False, "signalAuthorityRetired": False, "groupSignals": []}
    reader_summary = ReaderSummary(False, 0, False, "not-started")
    reader = None
    proc = None
    root = None
    tracked = set()
    lineage = set()
    known_parents = {}
    escapes = set()
    reparented = set()
    samples = 0
    first_resource = {}
    last_resource = {}
    exit_code = None
    try:
        if io.clock() >= work_deadline:
            raise ScopeError("phase-deadline")
        proc = io.spawn(argv, environment, cwd, deadline=closure_deadline)
        try:
            root = io.identity(proc.pid, deadline=work_deadline)
        except Exception as error:
            primary = "post-spawn-setup:" + type(error).__name__
            try:
                io.abort(proc, deadline=closure_deadline)
            except Exception as cleanup_error:
                cleanup_failures.append("abort:" + type(cleanup_error).__name__)
            closure["reason"] = "root-identity-unknown"
            return PhaseResult(name, argv, None, primary, cleanup_failures, resource_violations, closure, 0, False, started, io.clock(), None, samples, first_resource, last_resource, [], [])
        tracked = {root}
        lineage = {root}
        known_parents = {root: root.pid}
        reader = io.start_reader(proc.child, name)
        next_resource = 0.0
        last_complete_observation = started
        while True:
            now = io.clock()
            if now >= work_deadline:
                primary = "phase-deadline"
                break
            if now > total_deadline:
                primary = "runtime-deadline"
                break
            try:
                table = io.process_table(deadline=min(work_deadline, last_complete_observation + MAX_OBSERVATION_GAP))
            except Exception as error:
                primary = "process-table:" + type(error).__name__
                break
            now = io.clock()
            if now >= work_deadline:
                primary = "phase-deadline"
                break
            if now > total_deadline:
                primary = "runtime-deadline"
                break
            state = discover_owned(table, root, tracked, root.pid, known_parents)
            tracked = state.tracked
            lineage = state.lineage
            known_parents = state.parents
            escapes |= state.escapes
            reparented |= state.reparented
            if now >= next_resource:
                if now - last_complete_observation > MAX_OBSERVATION_GAP:
                    primary = "observation-gap"
                    break
                sample = io.resources(deadline=min(work_deadline, last_complete_observation + MAX_OBSERVATION_GAP))
                samples += 1
                sample_end = io.clock()
                if sample_end - last_complete_observation > MAX_OBSERVATION_GAP:
                    primary = "observation-gap"
                    break
                last_complete_observation = sample_end
                if not first_resource:
                    first_resource = sample
                last_resource = sample
                issues = evaluate_resources(sample, resource_floor)
                if issues:
                    resource_violations = issues
                    primary = issues[0]
                    break
                now = io.clock()
                if now >= work_deadline:
                    primary = "phase-deadline"
                    break
                if now > total_deadline:
                    primary = "runtime-deadline"
                    break
                next_resource = min(sample_end + RESOURCE_INTERVAL, last_complete_observation + MAX_OBSERVATION_GAP - 1.0)
            if escapes:
                primary = "closure-incomplete"
                break
            if proc.wait_exit(0):
                break
            io.sleep(PROCESS_INTERVAL)
        closure, cleanup_failures = cleanup_phase(io, proc, root, tracked, root.pid, known_parents, min(closure_deadline, last_complete_observation + MAX_OBSERVATION_GAP), observed_escapes=escapes)
        exit_code = proc.child.returncode if proc.reaped else None
        try:
            reader_summary = reader.join(min(READER_JOIN_TIMEOUT, remaining_budget(closure_deadline, io.clock)))
        except Exception as error:
            reader_summary = ReaderSummary(False, 0, False, type(error).__name__)
        if primary is None and exit_code is None:
            primary = "phase-unfinished"
        if primary is None and exit_code != 0:
            primary = "phase-exit:" + str(exit_code)
        if not reader_summary.joined and primary is None:
            primary = "output-join-timeout"
        if reader_summary.error and primary is None:
            primary = "output-error:" + reader_summary.error
        if primary is None and not closure.get("complete"):
            primary = "closure-incomplete"
        if primary is None and cleanup_failures:
            primary = "cleanup-failure"
        if primary is None and io.clock() - last_complete_observation > MAX_OBSERVATION_GAP:
            primary = "observation-gap"
        if primary is None and io.clock() - started > deadline_seconds:
            primary = "phase-deadline"
        if primary is None and io.clock() > total_deadline:
            primary = "runtime-deadline"
    except BaseException as error:
        primary = primary or ("phase-deadline" if str(error) == "phase-deadline" else "post-spawn-exception:" + type(error).__name__)
        if proc is not None:
            try:
                io.abort(proc, deadline=closure_deadline)
            except Exception as cleanup_error:
                cleanup_failures.append("exception-cleanup:" + type(cleanup_error).__name__)
        if reader is not None:
            try:
                reader_summary = reader.join(min(READER_JOIN_TIMEOUT, remaining_budget(closure_deadline, io.clock)))
            except Exception as join_error:
                reader_summary = ReaderSummary(False, 0, False, type(join_error).__name__)
        if isinstance(error, (KeyboardInterrupt, SystemExit)):
            raise
    finally:
        if proc is not None and not proc.reaped:
            try:
                if proc.authority:
                    io.abort(proc, deadline=closure_deadline)
                else:
                    cleanup_failures.append("unreaped-retired-leader")
            except Exception as error:
                cleanup_failures.append("final-cleanup:" + type(error).__name__)
    return PhaseResult(
        name,
        argv,
        exit_code,
        primary,
        cleanup_failures,
        resource_violations,
        closure,
        reader_summary.total,
        reader_summary.truncated,
        started,
        io.clock(),
        [root.pid, root.start] if root else None,
        samples,
        first_resource,
        last_resource,
        closure.get("escapes", []),
        [[identity.pid, identity.start] for identity in sorted(reparented)],
    )


def prepare_evidence(evidence):
    if evidence.exists() or evidence.is_symlink():
        raise ScopeError("evidence-exists")
    evidence.mkdir(mode=0o700)
    for name in ("bin", "scratch", "cache", "configuration", "security", "home", "home/.cache", "tmp", "module-cache", "module-cache/swift", "module-cache/clang", "manifest-module-cache", "manifest-module-cache/swift", "manifest-module-cache/clang", "logs"):
        (evidence / name).mkdir(mode=0o700)
    (evidence / "home/gitconfig").write_text("", encoding="utf-8")
    (evidence / "home/gitconfig").chmod(0o600)


def check_resources(io, floor, label, admissions=None):
    sample = io.resources()
    issues = evaluate_resources(sample, floor)
    if admissions is not None:
        admissions.append({"phase": label, "resources": sample, "requiredFloorBytes": floor, "issues": issues})
    if issues:
        raise ScopeError(label + ":" + ",".join(issues))
    return sample


def check_no_products(evidence):
    for relative in ("products", "retained", "scratch/products", "scratch/debug", "scratch/release", "scratch/artifacts"):
        path = evidence / relative
        if path.exists():
            if relative == "scratch/artifacts" and path.is_dir() and not any(path.iterdir()):
                continue
            raise ScopeError("stale-output:" + relative)


def check_module_caches(evidence):
    for relative in ("module-cache/swift", "module-cache/clang"):
        path = evidence / relative
        if not path.is_dir() or any(path.iterdir()):
            raise ScopeError("module-cache-not-empty:" + relative)


def verify_dependencies(source, evidence, environment):
    lock = source / "Package.resolved"
    if sha256_file(lock) != PACKAGE_RESOLVED_SHA256:
        raise ScopeError("package-resolved-hash")
    pins = evaluate_pins(json.loads(lock.read_text(encoding="utf-8")))
    checkouts = evidence / "scratch/checkouts"
    if not checkouts.is_dir():
        raise ScopeError("checkouts-missing-directory")
    names = sorted(item.name for item in checkouts.iterdir() if item.is_dir() and not item.is_symlink())
    heads = {}
    for identity in names:
        heads[identity] = run_git(checkouts / identity, ("rev-parse", "HEAD"), environment)
    missing = set(pins) - set(names)
    issues = evaluate_checkouts(pins, heads, missing)
    if issues:
        raise ScopeError("checkouts:" + ",".join(issues))
    if "eventsource" in missing:
        package_text = (source / "Package.swift").read_text(encoding="utf-8")
        provenance_text = (source / "Vendor/EventSource/PROVENANCE.md").read_text(encoding="utf-8")
        issues = evaluate_eventsource(missing, package_text, provenance_text)
        if issues:
            raise ScopeError("eventsource:" + ",".join(issues))
    module_sets = {}
    for identity in names:
        gitmodules = checkouts / identity / ".gitmodules"
        module_sets[identity] = parse_gitmodules(gitmodules.read_text(encoding="utf-8")) if gitmodules.is_file() else {}
    nested_heads = {}
    nested_trees = {}
    for relative in NESTED:
        worktree = checkouts / "mlx-swift" / relative
        if not worktree.is_dir() or worktree.is_symlink():
            raise ScopeError("nested-submodules-missing:" + relative)
        nested_heads[relative] = run_git(worktree, ("rev-parse", "HEAD"), environment)
        nested_trees[relative] = run_git(worktree, ("rev-parse", "HEAD^{tree}"), environment)
    issues = evaluate_submodules(module_sets, nested_heads, nested_trees)
    if issues:
        raise ScopeError("submodules:" + ",".join(issues))
    check_no_products(evidence)
    return {
        "pins": {identity: {"version": version, "revision": revision} for identity, (version, revision) in pins.items()},
        "checkouts": {identity: {"revision": head} for identity, head in heads.items()},
        "missingCheckouts": sorted(missing),
        "nested": {relative: {"commitSHA": nested_heads[relative], "treeSHA": nested_trees[relative], "url": NESTED[relative][2]} for relative in NESTED},
    }


def build_environment(evidence, source, developer, real_swift):
    toolchain_bin = str(Path(real_swift).parent)
    shim = evidence / "bin/swift"
    if not shim.exists():
        shim.write_text(
            "#!/bin/bash\nset -euo pipefail\n"
            "real=" + shlex.quote(str(real_swift)) + "\n"
            "source_root=" + shlex.quote(str(source)) + "\n"
            "dist_root=" + shlex.quote(str(evidence / "products")) + "\n"
            "scratch=" + shlex.quote(str(evidence / "scratch")) + "\n"
            "cache=" + shlex.quote(str(evidence / "cache")) + "\n"
            "configuration=" + shlex.quote(str(evidence / "configuration")) + "\n"
            "security=" + shlex.quote(str(evidence / "security")) + "\n"
            "swift_cache=" + shlex.quote(str(evidence / "module-cache/swift")) + "\n"
            "clang_cache=" + shlex.quote(str(evidence / "module-cache/clang")) + "\n"
            "if [[ \"${1:-}\" == build ]]; then\n"
            "  shift\n"
            "  build_args=(\"$@\")\n"
            "  expected=(--build-system swiftbuild --configuration release --scratch-path \"$scratch\" --cache-path \"$cache\" --config-path \"$configuration\" --security-path \"$security\" --only-use-versions-from-resolved-file --arch arm64)\n"
            "  for argument in \"${expected[@]}\"; do\n"
            "    [[ \"${1:-}\" == \"$argument\" ]] || exit 64\n"
            "    shift\n"
            "  done\n"
            "  if ! { [[ $# -eq 2 && \"$1\" == --product && \"$2\" == imrse ]] || [[ $# -eq 1 && \"$1\" == --show-bin-path ]]; }; then exit 64; fi\n"
            "  exec \"$real\" build --jobs 1 --disable-experimental-prebuilts --skip-update -Xswiftc -module-cache-path -Xswiftc \"$swift_cache\" -Xcc \"-fmodules-cache-path=$clang_cache\" -Xcxx \"-fmodules-cache-path=$clang_cache\" \"${build_args[@]}\"\n"
            "fi\n"
            "if [[ $# -eq 2 && \"$1\" == \"$source_root/Resources/GenerateIcon.swift\" && \"$2\" == \"$dist_root/\"* ]]; then\n"
            "  relative=\"${2#\"$dist_root/\"}\"\n"
            "  if [[ \"$relative\" =~ ^\\.imrse-package\\.[A-Za-z0-9]{6}/imrse\\.iconset$ ]]; then\n"
            "    exec \"$real\" -module-cache-path \"$swift_cache\" -Xcc \"-fmodules-cache-path=$clang_cache\" \"$@\"\n"
            "  fi\n"
            "fi\n"
            "printf 'hosted build proxy rejected an unexpected swift invocation\\n' >&2\n"
            "exit 64\n",
            encoding="utf-8",
        )
        shim.chmod(0o700)
    return {
        "CONFIGURATION": "release",
        "IMRSE_CI_PACKAGE_VALIDATION": "1",
        "IMRSE_SOURCE_ROOT": str(source),
        "IMRSE_DIST_DIR": str(evidence / "products"),
        "SCRATCH_PATH": str(evidence / "scratch"),
        "SWIFTPM_CACHE_PATH": str(evidence / "cache"),
        "SWIFTPM_CONFIG_PATH": str(evidence / "configuration"),
        "SWIFTPM_SECURITY_PATH": str(evidence / "security"),
        "SWIFT_MODULECACHE_PATH": str(evidence / "module-cache/swift"),
        "SWIFT_MODULE_CACHE_PATH": str(evidence / "module-cache/swift"),
        "CLANG_MODULE_CACHE_PATH": str(evidence / "module-cache/clang"),
        "CLANG_MODULECACHE_PATH": str(evidence / "module-cache/clang"),
        "XDG_CACHE_HOME": str(evidence / "home/.cache"),
        "HOME": str(evidence / "home"),
        "TMPDIR": str(evidence / "tmp"),
        "PATH": str(evidence / "bin") + ":" + toolchain_bin + ":/usr/bin:/bin:/usr/sbin:/sbin",
        "DEVELOPER_DIR": developer,
        "GIT_ALLOW_PROTOCOL": "file",
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": str(evidence / "home/gitconfig"),
        "GIT_OPTIONAL_LOCKS": "0",
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONNOUSERSITE": "1",
    }


def resolve_environment(evidence, source, developer, real_swift):
    environment = build_environment(evidence, source, developer, real_swift)
    environment["GIT_ALLOW_PROTOCOL"] = "https"
    environment["SWIFT_MODULECACHE_PATH"] = str(evidence / "manifest-module-cache/swift")
    environment["SWIFT_MODULE_CACHE_PATH"] = str(evidence / "manifest-module-cache/swift")
    environment["CLANG_MODULE_CACHE_PATH"] = str(evidence / "manifest-module-cache/clang")
    environment["CLANG_MODULECACHE_PATH"] = str(evidence / "manifest-module-cache/clang")
    return environment


def post_build_checks(source, evidence, expected_commit, expected_tree, environment):
    app = evidence / "products/imrse.app"
    if not app.is_dir() or app.is_symlink():
        raise ScopeError("app-missing")
    for relative in ("Contents/_CodeSignature", "Contents/Resources/_CodeSignature", "Contents/embedded.provisionprofile"):
        if (app / relative).exists():
            raise ScopeError("app-signed:" + relative)
    receipt_path = app / "Contents/Resources/CI-PACKAGE-VALIDATION.json"
    try:
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise ScopeError("receipt-invalid") from error
    if receipt.get("validationMode") != "unsigned-ci-package-validation-only":
        raise ScopeError("receipt-mode")
    if receipt.get("codeSigningPerformed") is not False or receipt.get("distributionEligible") is not False:
        raise ScopeError("receipt-unsigned")
    if receipt.get("signingCertificateSHA1") is not None or receipt.get("releaseBuildProvenanceCreated") is not False:
        raise ScopeError("receipt-provenance")
    if receipt.get("source") != {"commitSHA": expected_commit, "treeSHA": expected_tree}:
        raise ScopeError("receipt-source")
    toplevel = run_git(source, ("rev-parse", "--show-toplevel"), environment)
    if Path(toplevel).resolve() != source.resolve():
        raise ScopeError("source-not-worktree-root")
    head = run_git(source, ("rev-parse", "HEAD"), environment)
    tree = run_git(source, ("rev-parse", "HEAD^{tree}"), environment)
    status = run_git(source, ("status", "--porcelain=v1", "--untracked-files=all"), environment)
    if head != expected_commit or tree != expected_tree or status:
        raise ScopeError("source-changed")
    return {"receiptSHA256": sha256_file(receipt_path), "executableSHA256": sha256_file(app / "Contents/MacOS/imrse")}


def artifact_identity(evidence):
    manifest_path = evidence / "retained/ci-test-app-manifest.json"
    checksums_path = evidence / "retained/SHA256SUMS"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("source") != {"commitSHA": SOURCE_COMMIT, "treeSHA": SOURCE_TREE}:
        raise ScopeError("retained-source")
    archive = evidence / "retained" / manifest["archive"]["file"]
    if sha256_file(archive) != manifest["archive"]["sha256"]:
        raise ScopeError("archive-hash")
    return {
        "manifestSHA256": sha256_file(manifest_path),
        "checksumsSHA256": sha256_file(checksums_path),
        "archive": manifest["archive"],
        "bundleIdentifier": manifest["app"]["bundleIdentifier"],
        "architecture": manifest["app"]["architecture"],
        "totalBytes": manifest["app"]["totalBytes"],
        "inventoryEntries": len(manifest["app"]["inventory"]),
        "ciValidationReceiptSHA256": manifest["app"]["ciValidationReceiptSHA256"],
    }


def write_json(path, payload):
    with path.open("x", encoding="utf-8") as destination:
        destination.write(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def main(argv=None):
    global _TOTAL_DEADLINE
    parser = argparse.ArgumentParser()
    parser.add_argument("--control", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--control-commit", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--source-tree", required=True)
    args = parser.parse_args(argv)

    def cancel(_signum, _frame):
        raise KeyboardInterrupt("cancelled")

    signal.signal(signal.SIGTERM, cancel)
    signal.signal(signal.SIGINT, cancel)

    control = args.control.resolve()
    source = args.source.resolve()
    evidence = args.evidence
    result = {
        "schemaVersion": 1,
        "route": "hosted-combined-535b7f8",
        "status": "running",
        "sourceCommit": SOURCE_COMMIT,
        "sourceTree": SOURCE_TREE,
        "controlCommit": args.control_commit,
        "phases": [],
        "admissions": [],
        "limitations": [
            "Unsigned CI package-validation output only; no code signature, notarization, installation, TCC grant, provider/model execution or live field editing is established.",
            "Closure is bounded observed closure, not atomic discovery: an unobserved transient or escaped process is outside the guarantee, and any observed escaped/unresolved identity makes the result incomplete.",
            "Process start identity uses ps lstart at one-second resolution; a PID reused within the same second with an identical lstart is indistinguishable.",
            "Signals are group-only through the retained direct leader's private session/group; no census PID is ever signalled. A known descendant that escapes the private group/session makes the phase incomplete and is never chased or killed.",
            "Metadata helpers use the same retained-leader group lifecycle; a metadata helper that escapes the private group/session is outside the observed guarantee.",
            "Only an allowlisted public receipt and log summary are exported; raw logs and result files remain on the runner. The workflow retains the sanitized receipts and any successfully validated unsigned app for seven days.",
        ],
    }
    io = None
    total_deadline = None
    environment = None
    created = False
    try:
        if args.source_commit != SOURCE_COMMIT or args.source_tree != SOURCE_TREE:
            raise ScopeError("requested-source-not-exact")
        if control == source or control in source.parents or source in control.parents:
            raise ScopeError("source-control-overlap")
        prepare_evidence(evidence)
        created = True
        environment = runtime_environment(evidence)
        io = SystemPhaseIO(evidence, evidence / "logs", environment)
        total_deadline = io.clock() + TOTAL_BUDGET
        _TOTAL_DEADLINE = total_deadline
        result["control"] = check_control(control, args.control_commit, environment)
        result["source"] = check_source(source, args.source_commit, args.source_tree, environment)
        result["toolchain"] = check_toolchain(environment)
        check_resources(io, INITIAL_FLOOR, "pre-dependency", result["admissions"])
        check_no_products(evidence)
        resolve = run_phase(
            io,
            "resolve",
            [
                result["toolchain"]["realSwift"],
                "package",
                "--package-path", str(source),
                "--scratch-path", str(evidence / "scratch"),
                "--cache-path", str(evidence / "cache"),
                "--config-path", str(evidence / "configuration"),
                "--security-path", str(evidence / "security"),
                "resolve",
                "--disable-automatic-resolution",
            ],
            resolve_environment(evidence, source, result["toolchain"]["developerDirectory"], result["toolchain"]["realSwift"]),
            source,
            RESOLVE_DEADLINE,
            RUNTIME_FLOOR,
            total_deadline,
        )
        result["phases"].append(resolve.to_dict())
        if not resolve.ok():
            raise ScopeError("resolve-not-ok:" + str(resolve.primaryFailure))
        result["dependencies"] = verify_dependencies(source, evidence, environment)
        result["source"] = check_source(source, args.source_commit, args.source_tree, environment)
        result["toolchain"] = check_toolchain(environment)
        verify_dependencies(source, evidence, environment)
        check_module_caches(evidence)
        check_resources(io, INITIAL_FLOOR, "pre-compiler", result["admissions"])
        build = run_phase(
            io,
            "build",
            ["/bin/bash", str(source / "scripts/build-app.sh")],
            build_environment(evidence, source, result["toolchain"]["developerDirectory"], result["toolchain"]["realSwift"]),
            source,
            BUILD_DEADLINE,
            RUNTIME_FLOOR,
            total_deadline,
        )
        result["phases"].append(build.to_dict())
        if not build.ok():
            raise ScopeError("build-not-ok:" + str(build.primaryFailure))
        check_resources(io, RUNTIME_FLOOR, "post-build", result["admissions"])
        result["product"] = post_build_checks(source, evidence, args.source_commit, args.source_tree, environment)
        retention = run_phase(
            io,
            "retention",
            [
                "/usr/bin/python3",
                str(source / "scripts/retain_ci_test_app.py"),
                "--source-root", str(source),
                "--expected-commit", args.source_commit,
                "--app", str(evidence / "products/imrse.app"),
                "--output-dir", str(evidence / "retained"),
                "--run-id", str(os.environ.get("GITHUB_RUN_ID", "")),
                "--run-attempt", str(os.environ.get("GITHUB_RUN_ATTEMPT", "")),
            ],
            build_environment(evidence, source, result["toolchain"]["developerDirectory"], result["toolchain"]["realSwift"]),
            source,
            RETENTION_DEADLINE,
            RUNTIME_FLOOR,
            total_deadline,
        )
        result["phases"].append(retention.to_dict())
        if not retention.ok():
            raise ScopeError("retention-not-ok:" + str(retention.primaryFailure))
        result["source"] = check_source(source, args.source_commit, args.source_tree, environment)
        result["artifact"] = artifact_identity(evidence)
        result["status"] = "passed"
    except KeyboardInterrupt:
        result["status"] = "cancelled"
        result["failure"] = "cancelled"
    except Exception as error:
        result["status"] = "failed"
        result["failure"] = type(error).__name__ + ": " + str(error)
    result["run"] = {key: os.environ.get(key, "") for key in ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_JOB", "GITHUB_WORKFLOW_REF", "RUNNER_NAME", "RUNNER_OS", "RUNNER_ARCH", "ImageVersion")}
    if created and evidence.is_dir():
        try:
            write_json(evidence / "hosted-combined-result.json", result)
        except OSError:
            pass
    print(json.dumps({"status": result["status"], "failureRecorded": result.get("failure") is not None, "phases": [{"name": phase["name"], "ok": phase["primaryFailure"] is None and not phase["cleanupFailures"] and phase["closure"].get("complete") and not phase["resourceViolations"]} for phase in result["phases"]]}, sort_keys=True))
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
