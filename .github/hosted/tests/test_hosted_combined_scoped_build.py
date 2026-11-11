import builtins
import fcntl
import importlib.util
from io import BytesIO
import os
from pathlib import Path
import select
import socket
import subprocess
import tempfile
import unittest
from unittest.mock import patch

HELPER_PATH = Path(__file__).resolve().parents[1] / "hosted_combined_scoped_build.py"
SPEC = importlib.util.spec_from_file_location("hosted_combined_scoped_build", HELPER_PATH)
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)

START_A = "Mon Jan  1 00:00:00 2026"
START_B = "Tue Jan  2 00:00:00 2026"
GIB = 1024**3
PROTECTED_PREFIXES = (
    "/Applications/imrse.app",
    "/Applications/imrse copy.app",
    str(Path.home() / "Library/Application Support/imrse"),
    str(Path.home() / "Fleck-builds/accepted"),
    "/System/Library/LaunchDaemons",
)
_REAL_OPEN = builtins.open
_REAL_PATH_OPEN = Path.open
_PATCHERS = []


def guarded_open(file, *args, **kwargs):
    if isinstance(file, (str, os.PathLike)):
        path = os.fspath(file)
        if path.startswith(PROTECTED_PREFIXES):
            raise AssertionError("protected read denied: " + path)
    return _REAL_OPEN(file, *args, **kwargs)


def guarded_path_open(self, *args, **kwargs):
    if str(self).startswith(PROTECTED_PREFIXES):
        raise AssertionError("protected read denied: " + str(self))
    return _REAL_PATH_OPEN(self, *args, **kwargs)


def setUpModule():
    _PATCHERS.extend(
        [
            patch.object(subprocess, "Popen", side_effect=AssertionError("subprocess spawn denied")),
            patch.object(subprocess, "run", side_effect=AssertionError("subprocess run denied")),
            patch.object(subprocess, "check_output", side_effect=AssertionError("subprocess check_output denied")),
            patch.object(os, "statvfs", side_effect=AssertionError("statvfs denied")),
            patch.object(os, "posix_spawn", side_effect=AssertionError("posix_spawn denied")),
            patch.object(os, "fork", side_effect=AssertionError("fork denied")),
            patch.object(os, "spawnv", side_effect=AssertionError("spawnv denied")),
            patch.object(os, "killpg", side_effect=AssertionError("killpg denied")),
            patch.object(fcntl, "flock", side_effect=AssertionError("flock denied")),
            patch.object(socket, "socket", side_effect=AssertionError("network denied")),
            patch.object(socket, "create_connection", side_effect=AssertionError("network denied")),
            patch.object(os, "system", side_effect=AssertionError("os.system denied")),
            patch.object(os, "popen", side_effect=AssertionError("os.popen denied")),
            patch.object(select, "kqueue", side_effect=AssertionError("kqueue denied")),
            patch.object(builtins, "open", side_effect=guarded_open),
            patch.object(Path, "open", new=guarded_path_open),
        ]
    )
    for patcher in _PATCHERS:
        patcher.start()


def tearDownModule():
    for patcher in reversed(_PATCHERS):
        patcher.stop()
    _PATCHERS.clear()


def row(pid, ppid, pgid, start=START_A, comm="swift-frontend"):
    return helper.ProcessRow(pid, ppid, pgid, start, comm)


def table(*rows):
    return helper.ProcessTable(list(rows))


def good_sample(filesystem=20 * GIB, apfs=20 * GIB, pressure="1", swap=0):
    return {
        "complete": True,
        "filesystemAvailableBytes": filesystem,
        "actualAPFSFreeBytes": apfs,
        "memoryPressure": pressure,
        "swapUsedBytes": swap,
    }


class FakeChild:
    def __init__(self, pid=100, stdout=b"", stderr=b""):
        self.pid = pid
        self.stdout = BytesIO(stdout)
        self.stderr = BytesIO(stderr)
        self.returncode = None


class FakeProcess:
    def __init__(self, pid=100, exited=False, exit_code=0, stdout=b""):
        self.pid = pid
        self.child = FakeChild(pid, stdout)
        self.exited = exited
        self.exit_data = 0
        self.authority = True
        self.reaped = False
        self.signals = []
        self.closed = False
        self.exit_code = exit_code
        self.events = []

    def wait_exit(self, timeout):
        if self.exited:
            return True
        return False

    def signal_group(self, signum):
        if not self.authority or self.reaped:
            raise helper.LifetimeError("signal-authority")
        self.signals.append(signum)
        self.events.append(("signal", signum))
        if not self.exited:
            self.exited = True
            self.child.returncode = -signum

    def retire_and_reap(self, timeout):
        if self.reaped:
            return self.child.returncode
        self.authority = False
        self.reaped = True
        self.events.append(("reap", None))
        self.child.returncode = self.exit_code if self.child.returncode is None else self.child.returncode
        return self.child.returncode

    def close(self):
        self.closed = True

    def group_absent(self):
        if not self.reaped or self.authority:
            raise helper.LifetimeError("group-probe-before-retirement")
        return True


class FakeReader:
    def __init__(self, joined=True, total=0, truncated=False, error=None):
        self.joined = joined
        self.total = total
        self.truncated = truncated
        self.error = error

    def join(self, timeout):
        return helper.ReaderSummary(self.joined, self.total, self.truncated, self.error)


class FakeIO:
    def __init__(self, rows=None, samples=None, proc=None, reader=None, identity_error=None, table_error=None, resource_error=None, retire_error=None, now=0.0, spawn_advance=0.0, sleep_step=0.2, remove_on_signal=True):
        self.rows = list(rows if rows is not None else [])
        self.samples = list(samples if samples is not None else [good_sample()])
        self.proc = proc or FakeProcess()
        self.reader = reader or FakeReader()
        self.identity_error = identity_error
        self.table_error = table_error
        self.resource_error = resource_error
        self.retire_error = retire_error
        self.now = now
        self.spawn_advance = spawn_advance
        self.sleep_step = sleep_step
        self.remove_on_signal = remove_on_signal
        self.signals = []
        self.aborted = False

    def clock(self):
        return self.now

    def sleep(self, seconds):
        self.now += self.sleep_step

    def spawn(self, argv, environment, cwd, deadline=None):
        self.now += self.spawn_advance
        return self.proc

    def identity(self, pid, deadline=None):
        if self.identity_error is not None:
            raise self.identity_error
        return helper.Identity(pid, START_A)

    def process_table(self, deadline=None):
        if self.table_error is not None:
            raise self.table_error
        return table(*self.rows)

    def resources(self, deadline=None):
        if self.resource_error is not None:
            raise self.resource_error
        if len(self.samples) > 1:
            return self.samples.pop(0)
        return self.samples[0]

    def start_reader(self, child, name):
        return self.reader

    def signal_group(self, proc, signum):
        self.signals.append((helper.Identity(proc.pid, START_A), signum))
        proc.signal_group(signum)
        if self.remove_on_signal:
            self.rows = [item for item in self.rows if item.pgid != proc.pid]

    def retire(self, proc, timeout):
        if self.retire_error is not None:
            raise self.retire_error
        return proc.retire_and_reap(timeout)

    def abort(self, proc, deadline=None):
        self.aborted = True
        if not proc.reaped:
            if proc.authority:
                self.signal_group(proc, helper.signal.SIGKILL)
            self.retire(proc, helper.REAP_TIMEOUT)


class PhaseControllerTests(unittest.TestCase):
    def run_phase(self, io, deadline=180, floor=helper.RUNTIME_FLOOR):
        return helper.run_phase(io, "phase", ["/bin/echo", "x"], {}, Path("/tmp"), deadline, floor, io.clock() + 3600)

    def test_post_spawn_setup_failure_aborts_group(self):
        io = FakeIO(identity_error=helper.IdentityError("missing"))
        result = self.run_phase(io)
        self.assertFalse(result.ok())
        self.assertTrue(result.primaryFailure.startswith("post-spawn-setup:"))
        self.assertTrue(io.aborted)
        self.assertTrue(io.proc.reaped)
        self.assertIn(helper.signal.SIGKILL, io.proc.signals)

    def test_resource_violation_is_primary_failure(self):
        io = FakeIO(proc=FakeProcess(exited=True), samples=[good_sample(swap=1)])
        result = self.run_phase(io)
        self.assertFalse(result.ok())
        self.assertEqual(result.primaryFailure, "zero-swap")
        self.assertEqual(result.resourceViolations, ["zero-swap"])

    def test_resource_incomplete_is_nonzero(self):
        io = FakeIO(proc=FakeProcess(exited=True), samples=[{"complete": False, "reason": "df"}])
        result = self.run_phase(io)
        self.assertFalse(result.ok())
        self.assertIn("resources-incomplete", result.primaryFailure)

    def test_phase_deadline(self):
        io = FakeIO(proc=FakeProcess(exited=False), spawn_advance=11)
        result = self.run_phase(io, deadline=10)
        self.assertFalse(result.ok())
        self.assertEqual(result.primaryFailure, "phase-deadline")

    def test_malformed_process_table_is_nonzero(self):
        io = FakeIO(proc=FakeProcess(exited=True), table_error=helper.ProcessTableError("process-table-malformed"))
        result = self.run_phase(io)
        self.assertFalse(result.ok())
        self.assertIn("process-table", result.primaryFailure)

    def test_output_join_timeout_is_nonzero(self):
        io = FakeIO(proc=FakeProcess(exited=True), reader=FakeReader(joined=False))
        result = self.run_phase(io)
        self.assertFalse(result.ok())
        self.assertEqual(result.primaryFailure, "output-join-timeout")

    def test_output_truncation_is_recorded_and_success_preserved(self):
        io = FakeIO(proc=FakeProcess(exited=True), reader=FakeReader(joined=True, total=helper.MAX_PHASE_OUTPUT_BYTES + 1, truncated=True))
        result = self.run_phase(io)
        self.assertTrue(result.outputTruncated)
        self.assertTrue(result.ok())
        self.assertIsNone(result.primaryFailure)

    def test_pid_reuse_and_foreign_group_are_not_signalled(self):
        io = FakeIO(rows=[row(100, 1, 100, start=START_B)], proc=FakeProcess(exited=True))
        result = self.run_phase(io)
        self.assertFalse(result.ok())
        self.assertEqual(io.signals, [])
        self.assertEqual(result.primaryFailure, "closure-incomplete")

    def test_surviving_group_descendant_is_signalled_by_owned_group(self):
        io = FakeIO(rows=[row(100, 1, 100), row(101, 100, 100, comm="metal")], proc=FakeProcess(exited=True))
        result = self.run_phase(io)
        self.assertTrue(result.ok())
        self.assertTrue(io.proc.signals)
        self.assertTrue(io.proc.reaped)
        self.assertTrue(io.proc.signals == [helper.signal.SIGTERM])

    def test_escaped_descendant_is_refused_without_individual_signal(self):
        io = FakeIO(rows=[row(100, 1, 100), row(101, 100, 200, comm="metal")], proc=FakeProcess(exited=True))
        result = self.run_phase(io)
        self.assertFalse(result.ok())
        self.assertEqual(result.primaryFailure, "closure-incomplete")
        self.assertTrue(io.proc.signals)
        self.assertNotIn((helper.Identity(101, START_A), helper.signal.SIGTERM), io.signals)

    def test_cleanup_failure_preserves_primary_failure(self):
        io = FakeIO(proc=FakeProcess(exited=True), samples=[good_sample(swap=1)], retire_error=helper.LifetimeError("reap-timeout"))
        result = self.run_phase(io)
        self.assertEqual(result.primaryFailure, "zero-swap")
        self.assertTrue(result.cleanupFailures)
        self.assertFalse(result.ok())

    def test_unjoinable_child_is_nonzero(self):
        io = FakeIO(proc=FakeProcess(exited=True), retire_error=helper.LifetimeError("reap-timeout"))
        result = self.run_phase(io)
        self.assertFalse(result.ok())
        self.assertTrue(result.cleanupFailures)

    def test_resource_observation_gap_is_nonzero(self):
        class SlowResources(FakeIO):
            def resources(self, deadline=None):
                self.now += 20
                return good_sample()
        io = SlowResources(proc=FakeProcess(exited=True))
        result = self.run_phase(io)
        self.assertFalse(result.ok())
        self.assertEqual(result.primaryFailure, "observation-gap")

    def test_cancellation_cleans_up_and_reraises(self):
        io = FakeIO(proc=FakeProcess(exited=False), resource_error=KeyboardInterrupt("cancelled"))
        with self.assertRaises(KeyboardInterrupt):
            self.run_phase(io)
        self.assertTrue(io.proc.reaped)
        self.assertIn(helper.signal.SIGKILL, io.proc.signals)

    def test_reader_exception_is_nonzero(self):
        io = FakeIO(proc=FakeProcess(exited=True), reader=FakeReader(joined=True, error="OSError: closed"))
        result = self.run_phase(io)
        self.assertFalse(result.ok())
        self.assertIn("output-error", result.primaryFailure)


class LifetimeInvariantTests(unittest.TestCase):
    def test_no_signal_after_reap(self):
        proc = FakeProcess(exited=True)
        proc.retire_and_reap(1)
        with self.assertRaises(helper.LifetimeError):
            proc.signal_group(helper.signal.SIGKILL)

    def test_exited_unreaped_group_permission_error_is_not_a_signal_failure(self):
        child = self.FakePopen()
        proc = helper.RetainedProcess(child, self.FakeWatcher(), child.pid)
        proc.exited = True
        with patch.object(helper.os, "killpg", side_effect=PermissionError) as kill:
            proc.signal_group(helper.signal.SIGKILL)
        kill.assert_called_once_with(child.pid, helper.signal.SIGKILL)
        self.assertEqual(proc.signals, [])

    def test_running_group_permission_error_remains_a_signal_failure(self):
        child = self.FakePopen()
        proc = helper.RetainedProcess(child, self.FakeWatcher(), child.pid)
        with patch.object(helper.os, "killpg", side_effect=PermissionError):
            with self.assertRaises(helper.LifetimeError):
                proc.signal_group(helper.signal.SIGKILL)
        self.assertEqual(proc.signals, [])

    def test_no_reap_before_last_signal(self):
        proc = FakeProcess(exited=False)
        io = FakeIO(rows=[row(100, 1, 100), row(101, 100, 100)], proc=proc)
        helper.cleanup_phase(io, proc, helper.Identity(100, START_A), {helper.Identity(100, START_A)}, 100, {helper.Identity(100, START_A): 1}, 90)
        self.assertTrue(proc.signals)
        self.assertTrue(proc.reaped)
        self.assertEqual(proc.events[-1], ("reap", None))
        self.assertTrue(all(event[0] == "signal" for event in proc.events[:-1]))

    class FakePopen:
        def __init__(self):
            self.pid = 200
            self.stdout = BytesIO()
            self.stderr = BytesIO()
            self.returncode = None
            self.waited = False

        def wait(self, timeout=None):
            self.waited = True
            self.returncode = 0
            return 0

    class FakeEvent:
        def __init__(self, pid):
            self.ident = pid
            self.filter = select.KQ_FILTER_PROC
            self.fflags = select.KQ_NOTE_EXIT
            self.data = 0

    class FakeWatcher:
        def __init__(self, fail=False, early=False):
            self.fail = fail
            self.early = early
            self.closed = False

        def control(self, changes, max_events, timeout):
            if self.fail:
                raise OSError("watch")
            if self.early:
                return [LifetimeInvariantTests.FakeEvent(200)]
            return []

        def close(self):
            self.closed = True

    def test_watch_setup_failure_closes_group_while_leader_held(self):
        child = self.FakePopen()
        watcher = self.FakeWatcher(fail=True)
        with patch.object(helper, "require_process_lifetime_support", return_value=None), patch.object(helper.subprocess, "Popen", return_value=child), patch.object(helper.select, "kqueue", return_value=watcher), patch.object(helper.select, "kevent", return_value=object()), patch.object(helper.os, "killpg") as kill:
            with self.assertRaises(helper.LifetimeError):
                helper.RetainedProcess.spawn(["/bin/true"], {}, None)
        self.assertTrue(kill.called)
        self.assertTrue(child.waited)
        self.assertTrue(watcher.closed)

    def test_early_exit_watch_is_non_reaping(self):
        child = self.FakePopen()
        watcher = self.FakeWatcher(early=True)
        with patch.object(helper, "require_process_lifetime_support", return_value=None), patch.object(helper.subprocess, "Popen", return_value=child), patch.object(helper.select, "kqueue", return_value=watcher), patch.object(helper.select, "kevent", return_value=object()):
            proc = helper.RetainedProcess.spawn(["/bin/true"], {}, None)
        self.assertTrue(proc.exited)
        self.assertFalse(proc.reaped)
        self.assertFalse(child.waited)
        proc.close()

    def test_default_sigchld_refusal(self):
        with patch.object(helper.signal, "getsignal", return_value=object()):
            with self.assertRaises(helper.LifetimeError):
                helper.require_process_lifetime_support()

    def test_kqueue_unsupported_refusal(self):
        with patch.object(helper.select, "kqueue", new=None):
            with self.assertRaises(helper.LifetimeError):
                helper.require_process_lifetime_support()

    def test_capability_refusal_precedes_spawn(self):
        with patch.object(helper, "require_process_lifetime_support", side_effect=helper.LifetimeError("kqueue-unavailable")), patch.object(helper.subprocess, "Popen") as spawned:
            with self.assertRaises(helper.LifetimeError):
                helper.RetainedProcess.spawn(["/bin/true"], {}, None)
        spawned.assert_not_called()


class MetadataBoundaryTests(unittest.TestCase):
    class FakePopen:
        def __init__(self, stdout=b"", stderr=b"", code=0):
            self.pid = 4242
            self.stdout = BytesIO(stdout)
            self.stderr = BytesIO(stderr)
            self.returncode = None
            self.exit_code = code

        def wait(self, timeout=None):
            self.returncode = self.exit_code
            return self.returncode

    def fake_process(self, stdout=b"", exited=True):
        proc = FakeProcess(pid=4242, exited=exited, exit_code=0, stdout=stdout)
        proc.child.returncode = 0 if exited else None
        return proc

    def test_run_bounded_normal_output_is_bounded(self):
        proc = self.fake_process(b"ok")
        with patch.object(helper.RetainedProcess, "spawn", return_value=proc):
            result = helper.run_bounded(["/bin/ps"], {}, 5, max_bytes=1024)
        self.assertEqual(result.stdout, b"ok")
        self.assertTrue(proc.reaped)

    def test_run_bounded_exited_group_permission_error_keeps_its_output(self):
        child = self.FakePopen(b"ok")
        proc = helper.RetainedProcess(child, LifetimeInvariantTests.FakeWatcher(), child.pid)
        proc.exited = True
        with patch.object(helper.RetainedProcess, "spawn", return_value=proc), patch.object(helper.os, "killpg", side_effect=[PermissionError, ProcessLookupError]):
            result = helper.run_bounded(["/bin/ps"], {}, 5)
        self.assertEqual(result.stdout, b"ok")
        self.assertEqual(result.returncode, 0)
        self.assertTrue(proc.reaped)
        self.assertEqual(proc.signals, [])

    def test_run_bounded_exited_group_permission_error_does_not_prove_closure(self):
        for probe_result in (None, PermissionError()):
            with self.subTest(probe_result=type(probe_result).__name__):
                child = self.FakePopen(b"ok")
                proc = helper.RetainedProcess(child, LifetimeInvariantTests.FakeWatcher(), child.pid)
                proc.exited = True
                with patch.object(helper.RetainedProcess, "spawn", return_value=proc), patch.object(helper.os, "killpg", side_effect=[PermissionError(), probe_result]):
                    with self.assertRaisesRegex(helper.ScopeError, "metadata-incomplete:group-absence"):
                        helper.run_bounded(["/bin/ps"], {}, 5)
                self.assertTrue(proc.reaped)
                self.assertFalse(proc.authority)

    def test_run_bounded_oversize_is_rejected_and_group_closed(self):
        proc = self.fake_process(b"x" * 100)
        with patch.object(helper.RetainedProcess, "spawn", return_value=proc):
            with self.assertRaises(helper.ScopeError):
                helper.run_bounded(["/bin/ps"], {}, 5, max_bytes=10)
        self.assertTrue(proc.signals)
        self.assertEqual(proc.events[-1], ("reap", None))

    def test_run_bounded_timeout_closes_group(self):
        proc = self.fake_process(b"", exited=False)
        with patch.object(helper.RetainedProcess, "spawn", return_value=proc):
            with self.assertRaises(helper.ScopeError):
                helper.run_bounded(["/bin/ps"], {}, 0.05)
        self.assertTrue(proc.signals)
        self.assertTrue(proc.reaped)

    def test_run_bounded_cancellation_closes_group(self):
        proc = self.fake_process(b"", exited=False)
        with patch.object(helper.RetainedProcess, "spawn", return_value=proc), patch.object(helper.time, "sleep", side_effect=KeyboardInterrupt("cancelled")):
            with self.assertRaises(KeyboardInterrupt):
                helper.run_bounded(["/bin/ps"], {}, 5)
        self.assertTrue(proc.signals)
        self.assertTrue(proc.reaped)

    TOOLCHAIN_PROBES = {
        ("/usr/bin/uname", "-sm"): b"Darwin arm64",
        ("/usr/bin/sw_vers", "-productVersion"): b"27.0",
        ("/usr/bin/xcode-select", "-p"): b"/Applications/Xcode_27.app/Contents/Developer",
        ("/usr/bin/xcodebuild", "-version"): b"Xcode 27.1\nBuild version 27A9275",
        ("/usr/bin/xcrun", "swift", "--version"): b"Apple Swift version 6.4 (swiftlang-6.4.0.34.1)\nTarget: arm64-apple-macosx27.0.0",
        ("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"): b"27.0",
        ("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"): b"/Applications/Xcode_27.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.0.sdk",
        ("/usr/bin/xcrun", "--find", "swift"): b"/Applications/Xcode_27.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift",
        ("/usr/bin/xcrun", "--sdk", "macosx", "metal", "--version"): b"Apple metal version 32027.1 (metalfe-32027.1)",
        ("/usr/bin/xcrun", "swift", "build", "--help"): b"swiftbuild --only-use-versions-from-resolved-file --jobs --disable-experimental-prebuilts --skip-update",
    }

    def stub_toolchain(self, package_help):
        probes = dict(self.TOOLCHAIN_PROBES)
        probes[("/usr/bin/xcrun", "swift", "package", "--help")] = package_help
        observed = []

        def bounded(argv, environment, timeout, **kwargs):
            observed.append(argv)
            payload = probes.get(tuple(argv))
            if payload is None:
                raise AssertionError("unexpected toolchain probe: " + repr(argv))
            return subprocess.CompletedProcess(argv, 0, payload, b"")

        return observed, bounded

    def test_toolchain_probes_visible_global_package_help_for_the_lockfile_flag(self):
        observed, bounded = self.stub_toolchain(b"OPTIONS:\n  --disable-automatic-resolution  Only use versions from the Package.resolved file")
        with patch.object(helper, "run_bounded", side_effect=bounded):
            observations = helper.check_toolchain({})
        self.assertEqual(observations["packageHelp"], "OPTIONS:\n  --disable-automatic-resolution  Only use versions from the Package.resolved file")
        self.assertIn(["/usr/bin/xcrun", "swift", "package", "--help"], observed)
        self.assertNotIn(["/usr/bin/xcrun", "swift", "package", "resolve", "--help"], observed)

    def test_toolchain_refuses_a_missing_global_lockfile_flag(self):
        observed, bounded = self.stub_toolchain(b"OPTIONS:\n  --package-path  Specify the package path to operate on")
        with patch.object(helper, "run_bounded", side_effect=bounded):
            with self.assertRaisesRegex(helper.ScopeError, "toolchain:resolve-flag"):
                helper.check_toolchain({})
        self.assertIn(["/usr/bin/xcrun", "swift", "package", "--help"], observed)

    def test_system_phase_identity_uses_bounded_helper(self):
        completed = subprocess.CompletedProcess(["/bin/ps"], 0, b"4242 Mon Jan  1 00:00:00 2026\n", b"")
        with patch.object(helper, "run_bounded", return_value=completed) as bounded:
            identity = helper.SystemPhaseIO(Path("/tmp"), Path("/tmp"), {}).identity(4242)
        self.assertEqual(identity, helper.Identity(4242, "Mon Jan 1 00:00:00 2026"))
        bounded.assert_called_once()


class PureDecisionTests(unittest.TestCase):
    def test_parse_process_table_valid(self):
        parsed = helper.parse_process_table("  100     1   100 Mon Jan  1 00:00:00 2026 /usr/bin/swift\n")
        self.assertEqual(parsed.rows[0].pid, 100)
        self.assertEqual(parsed.rows[0].ppid, 1)
        self.assertEqual(parsed.rows[0].pgid, 100)
        self.assertEqual(parsed.rows[0].comm, "/usr/bin/swift")

    def test_parse_process_table_malformed(self):
        with self.assertRaises(helper.ProcessTableError):
            helper.parse_process_table("not a process row")

    def test_parse_process_table_oversize(self):
        with self.assertRaises(helper.ProcessTableError):
            helper.parse_process_table("x" * 10, max_bytes=5)

    def test_discover_reparenting_and_group_escape(self):
        root = helper.Identity(100, START_A)
        first = table(row(100, 1, 100), row(101, 100, 100))
        state = helper.discover_owned(first, root, {root}, 100, {root: 1})
        self.assertEqual(state.lineage, {root, helper.Identity(101, START_A)})
        second = table(row(101, 1, 200))
        state = helper.discover_owned(second, root, state.tracked, 100, state.parents)
        self.assertIn(helper.Identity(101, START_A), state.reparented)
        self.assertIn(helper.Identity(101, START_A), state.escapes)
        self.assertEqual(state.tracked, {root, helper.Identity(101, START_A)})

    def test_foreign_same_group_never_becomes_lineage(self):
        root = helper.Identity(100, START_A)
        foreign = helper.Identity(100, START_B)
        snapshot = table(row(100, 1, 100, start=START_B))
        first = helper.discover_owned(snapshot, root, {root}, 100, {})
        second = helper.discover_owned(snapshot, root, first.tracked, 100, first.parents)
        self.assertNotIn(foreign, second.lineage)

    def test_disappeared_owned_identity_remains_tracked(self):
        root = helper.Identity(100, START_A)
        child = helper.Identity(101, START_A)
        state = helper.discover_owned(table(row(100, 1, 100)), root, {root, child}, 100, {})
        self.assertIn(child, state.tracked)

    def test_evaluate_resources_floors(self):
        self.assertEqual(helper.evaluate_resources(good_sample(), 16 * GIB), [])
        self.assertEqual(helper.evaluate_resources(good_sample(filesystem=15 * GIB), 16 * GIB), ["disk-floor"])
        self.assertEqual(helper.evaluate_resources(good_sample(pressure="2"), 12 * GIB), ["memory-pressure"])
        self.assertEqual(helper.evaluate_resources(good_sample(swap=1), 12 * GIB), ["zero-swap"])
        self.assertEqual(helper.evaluate_resources({"complete": False, "reason": "df"}, 12 * GIB), ["resources-incomplete:df"])

    def test_evaluate_pins(self):
        payload = {"pins": [{"identity": identity, "state": {"version": version, "revision": revision}} for identity, (version, revision) in helper.PINS.items()]}
        self.assertEqual(helper.evaluate_pins(payload), helper.PINS)
        payload["pins"][0]["state"]["revision"] = "0" * 40
        with self.assertRaises(helper.ScopeError):
            helper.evaluate_pins(payload)

    def test_evaluate_checkouts_and_eventsource(self):
        heads = {identity: revision for identity, (_, revision) in helper.PINS.items() if identity != "eventsource"}
        self.assertEqual(helper.evaluate_checkouts(helper.PINS, heads, {"eventsource"}), [])
        self.assertTrue(helper.evaluate_checkouts(helper.PINS, heads, {"lottie-ios"}))
        self.assertTrue(helper.evaluate_checkouts(helper.PINS, {**heads, "extra": "a" * 40}, {"eventsource"}))
        self.assertEqual(helper.evaluate_eventsource({"eventsource"}, '.package(path: "Vendor/EventSource")', helper.PINS["eventsource"][1]), [])
        self.assertTrue(helper.evaluate_eventsource({"eventsource"}, "missing", "missing"))

    def test_evaluate_submodules(self):
        module_sets = {"mlx-swift": {relative: values[2] for relative, values in helper.NESTED.items()}}
        heads = {relative: values[0] for relative, values in helper.NESTED.items()}
        trees = {relative: values[1] for relative, values in helper.NESTED.items()}
        self.assertEqual(helper.evaluate_submodules(module_sets, heads, trees), [])
        broken = dict(heads)
        broken["Source/Cmlx/mlx"] = "0" * 40
        self.assertTrue(helper.evaluate_submodules(module_sets, broken, trees))
        self.assertTrue(helper.evaluate_submodules({"mlx-swift": {"extra": "https://example.invalid"}}, heads, trees))

    def test_evaluate_toolchain(self):
        good = {
            "uname": "Darwin arm64",
            "osVersion": "27.0",
            "xcode": "Xcode 27.1\nBuild version 27A123",
            "swift": "Apple Swift version 6.4 (swiftlang-6.4.0)",
            "sdkVersion": "27.0",
            "metalExitCode": 0,
            "buildHelp": "swiftbuild --only-use-versions-from-resolved-file --jobs --disable-experimental-prebuilts --skip-update",
            "packageHelp": "--disable-automatic-resolution",
            "realSwift": "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift",
        }
        self.assertEqual(helper.evaluate_toolchain(good), [])
        bad = dict(good, uname="Darwin x86_64", osVersion="26.6", xcode="Xcode 26.6", swift="Apple Swift version 6.2", sdkVersion="26.0", metalExitCode=1, buildHelp="", realSwift="swift")
        self.assertTrue(helper.evaluate_toolchain(bad))
        self.assertEqual(helper.evaluate_toolchain(dict(good, packageHelp="OPTIONS: --package-path --cache-path")), ["resolve-flag"])


class BuildEnvironmentTests(unittest.TestCase):
    def test_fixed_build_flags_shim_is_written_and_precedes_toolchain(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence = Path(directory)
            (evidence / "bin").mkdir()
            environment = helper.build_environment(evidence, Path("/tmp"), "/Applications/Xcode.app/Contents/Developer", "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift")
            shim = (evidence / "bin/swift").read_text(encoding="utf-8")
        self.assertIn("--jobs 1", shim)
        self.assertIn("--disable-experimental-prebuilts", shim)
        self.assertIn("--skip-update", shim)
        self.assertTrue(environment["PATH"].startswith(str(evidence / "bin") + ":"))


class ReviewCorrectionTests(unittest.TestCase):
    class ReadyReader:
        def __init__(self, stream, state):
            self.stream = stream
            self.data = b""
            self.error = None
            self.thread = self

        def start(self):
            return self

        def is_alive(self):
            return False

        def join(self, timeout):
            return True

    def test_group_absence_requires_retired_reaped_leader(self):
        child = LifetimeInvariantTests.FakePopen()
        proc = helper.RetainedProcess(child, LifetimeInvariantTests.FakeWatcher(), child.pid)
        with patch.object(helper.os, "killpg") as probe:
            with self.assertRaises(helper.LifetimeError):
                proc.group_absent()
        probe.assert_not_called()

    def test_surviving_or_reused_group_is_not_absence(self):
        child = LifetimeInvariantTests.FakePopen()
        proc = helper.RetainedProcess(child, LifetimeInvariantTests.FakeWatcher(), child.pid)
        proc.retire_and_reap(1)
        with patch.object(helper.os, "killpg") as probe:
            self.assertFalse(proc.group_absent())
        probe.assert_called_once_with(child.pid, 0)

    def test_missing_group_is_observed_with_signal_zero_only(self):
        child = LifetimeInvariantTests.FakePopen()
        proc = helper.RetainedProcess(child, LifetimeInvariantTests.FakeWatcher(), child.pid)
        proc.retire_and_reap(1)
        with patch.object(helper.os, "killpg", side_effect=ProcessLookupError) as probe:
            self.assertTrue(proc.group_absent())
        probe.assert_called_once_with(child.pid, 0)

    def test_permission_error_never_proves_group_absence(self):
        child = LifetimeInvariantTests.FakePopen()
        proc = helper.RetainedProcess(child, LifetimeInvariantTests.FakeWatcher(), child.pid)
        proc.retire_and_reap(1)
        with patch.object(helper.os, "killpg", side_effect=PermissionError):
            with self.assertRaises(helper.LifetimeError):
                proc.group_absent()

    def test_metadata_group_observation_follows_last_signal_and_reap(self):
        proc = FakeProcess(exited=True)
        def absent():
            self.assertTrue(proc.reaped)
            self.assertFalse(proc.authority)
            proc.events.append(("probe", 0))
            return True
        with patch.object(helper.RetainedProcess, "spawn", return_value=proc), patch.object(helper, "_CappedReader", self.ReadyReader), patch.object(proc, "group_absent", side_effect=absent):
            result = helper.run_bounded(["mock"], {}, 5)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(proc.events, [("signal", helper.signal.SIGKILL), ("reap", None), ("probe", 0)])

    def test_metadata_surviving_group_is_refused_without_waiting(self):
        clock = [0.0]
        proc = FakeProcess(exited=True)
        def sleep(seconds):
            clock[0] += 1
        with patch.object(helper.RetainedProcess, "spawn", return_value=proc), patch.object(helper, "_CappedReader", self.ReadyReader), patch.object(helper.time, "monotonic", side_effect=lambda: clock[0]), patch.object(helper.time, "sleep", side_effect=sleep), patch.object(proc, "group_absent", return_value=False):
            with self.assertRaises(helper.ScopeError) as failure:
                helper.run_bounded(["mock"], {}, 5)
        self.assertIn("group-absence", str(failure.exception))
        self.assertIn("group-present-after-retirement", str(failure.exception))
        self.assertEqual(clock[0], 0)
        self.assertEqual(proc.events, [("signal", helper.signal.SIGKILL), ("reap", None)])

    def test_observed_group_presence_cannot_be_retried_into_success(self):
        proc = FakeProcess(exited=True)
        with patch.object(helper.RetainedProcess, "spawn", return_value=proc), patch.object(helper, "_CappedReader", self.ReadyReader), patch.object(proc, "group_absent", side_effect=[False, True]) as absence:
            with self.assertRaises(helper.ScopeError) as failure:
                helper.run_bounded(["mock"], {}, 5)
        self.assertIn("group-present-after-retirement", str(failure.exception))
        absence.assert_called_once()

    def test_late_absence_observation_cannot_return_success(self):
        clock = [0.0]
        proc = FakeProcess(exited=True)
        def absent():
            clock[0] = 6
            return True
        with patch.object(helper.RetainedProcess, "spawn", return_value=proc), patch.object(helper, "_CappedReader", self.ReadyReader), patch.object(helper.time, "monotonic", side_effect=lambda: clock[0]), patch.object(proc, "group_absent", side_effect=absent):
            with self.assertRaises(helper.ScopeError) as failure:
                helper.run_bounded(["mock"], {}, 5)
        self.assertIn("group-absence", str(failure.exception))

    def test_final_oversize_does_not_replace_existing_primary_failure(self):
        state = {}
        proc = FakeProcess(exited=True)
        class Reader(self.ReadyReader):
            def __init__(self, stream, capture):
                super().__init__(stream, capture)
                state["capture"] = capture
        def exit_observation(timeout):
            state["capture"]["oversize"] = True
            raise helper.ScopeError("existing-primary")
        with patch.object(helper.RetainedProcess, "spawn", return_value=proc), patch.object(helper, "_CappedReader", Reader), patch.object(proc, "wait_exit", side_effect=exit_observation):
            with self.assertRaises(helper.ScopeError) as failure:
                helper.run_bounded(["mock"], {}, 5)
        self.assertEqual(str(failure.exception), "existing-primary")

    def test_final_exit_oversize_is_the_specific_primary_failure(self):
        state = {}
        proc = FakeProcess(exited=True)
        class Reader(self.ReadyReader):
            def __init__(self, stream, capture):
                super().__init__(stream, capture)
                state["capture"] = capture
        def exit_observation(timeout):
            state["capture"]["oversize"] = True
            return True
        with patch.object(helper.RetainedProcess, "spawn", return_value=proc), patch.object(helper, "_CappedReader", Reader), patch.object(proc, "wait_exit", side_effect=exit_observation):
            with self.assertRaises(helper.ScopeError) as failure:
                helper.run_bounded(["mock"], {}, 5)
        self.assertEqual(str(failure.exception), "metadata-output-oversize:mock")

    def test_failed_resource_command_identity_is_retained(self):
        from types import SimpleNamespace
        import plistlib
        outputs = [
            b"Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/disk9s1 1 0 1 0% /\n",
            plistlib.dumps({"APFSContainerReference": "disk9"}),
            plistlib.dumps({"Containers": [{"ContainerReference": "disk9", "CapacityFree": 20 * GIB}]}),
            b"1\n",
            b"total = 0.00M used = 0.00M free = 0.00M\n",
        ]
        for failed, name in enumerate(["df", "diskutil-info", "diskutil-apfs", "sysctl-pressure", "sysctl-swap"]):
            with self.subTest(command=name):
                results = [SimpleNamespace(returncode=7 if index == failed else 0, stdout=payload, stderr=b"error") for index, payload in enumerate(outputs)]
                with patch.object(helper.time, "monotonic", return_value=0), patch.object(helper.os, "statvfs", return_value=SimpleNamespace(f_bavail=20 * GIB, f_frsize=1)), patch.object(helper, "run_bounded", side_effect=results):
                    result = helper.SystemPhaseIO(Path("/fixture"), Path("/fixture/logs"), {}).resources(deadline=10)
                self.assertFalse(result["complete"])
                self.assertIn("resource-command:" + name + ":exit:7", result["reason"])

    def test_proxy_has_fixed_shapes_explicit_caches_and_no_fallback(self):
        with patch.object(helper.Path, "exists", return_value=False), patch.object(helper.Path, "write_text") as write, patch.object(helper.Path, "chmod"):
            helper.build_environment(Path("/fixture/evidence"), Path("/fixture/source"), "/fixture/developer", "/fixture/toolchain/swift")
        script = write.call_args.args[0]
        for fragment in ["-Xswiftc -module-cache-path -Xswiftc", '-Xcc "-fmodules-cache-path=$clang_cache"', '-Xcxx "-fmodules-cache-path=$clang_cache"', "/fixture/evidence/module-cache/swift", "/fixture/evidence/module-cache/clang", "--arch arm64", "--product", "--show-bin-path", "Resources/GenerateIcon.swift", "[A-Za-z0-9]{6}", "exit 64"]:
            self.assertIn(fragment, script)
        self.assertNotIn('exec "$real" "$@"', script)


class OuterDenialTests(unittest.TestCase):
    def test_subprocess_spawn_is_denied(self):
        with self.assertRaises(AssertionError):
            subprocess.Popen(["true"])

    def test_network_is_denied(self):
        with self.assertRaises(AssertionError):
            socket.socket()

    def test_kqueue_creation_is_denied(self):
        with self.assertRaises(AssertionError):
            select.kqueue()

    def test_protected_read_is_denied(self):
        with self.assertRaises(AssertionError):
            Path("/Applications/imrse.app/Contents/MacOS/imrse").read_bytes()


if __name__ == "__main__":
    unittest.main()
