#!/usr/bin/env python3
"""Reviewed synthetic-only probe supervisor. Requires explicit owner approval."""
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile
import threading

ROOT = pathlib.Path('/tmp/imrse-dot-native-panel-probe')
BINARY = ROOT / 'products/PanelProbe.app/Contents/MacOS/PanelProbe'
manifest = json.loads((ROOT / 'build.json').read_text())
assert not BINARY.is_symlink() and BINARY.is_file()
assert hashlib.sha256(BINARY.read_bytes()).hexdigest() == manifest['binarySHA256']
subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(BINARY.parents[2])], check=True)
run = pathlib.Path(tempfile.mkdtemp(prefix='imrse-native-panel-probe-', dir='/tmp'))
p = subprocess.Popen([str(BINARY)], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                     stderr=subprocess.PIPE, close_fds=True, start_new_session=True,
                     env={'PATH': '/usr/bin:/bin', 'HOME': str(pathlib.Path.home()), 'LANG': 'en_US.UTF-8'})
try:
    buffers = [bytearray(), bytearray()]
    overflow = [False, False]
    def drain(stream, index):
        while True:
            block = stream.read(4096)
            if not block:
                return
            remaining = 65536 - len(buffers[index])
            buffers[index].extend(block[:max(0, remaining)])
            if len(block) > remaining:
                overflow[index] = True
    workers = [threading.Thread(target=drain, args=(stream, index), daemon=True)
               for index, stream in enumerate([p.stdout, p.stderr])]
    for worker in workers:
        worker.start()
    print(json.dumps({'pid': p.pid, 'runDirectory': str(run), 'binarySHA256': manifest['binarySHA256']}), flush=True)
    timed_out = False
    try:
        p.wait(timeout=45)
    except subprocess.TimeoutExpired:
        timed_out = True
        p.terminate()  # Only this owned child; no PID discovery or external application termination.
        try:
            p.wait(timeout=2)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait(timeout=2)
    for worker in workers:
        worker.join(timeout=2)
    keys = {'event', 'sample', 'ownAppActive', 'ownAppForeground', 'ownPanelKey',
            'fieldAcceptsFirstResponder', 'responderRequestAccepted',
            'actualFieldEditorIsFirstResponder', 'matchesSyntheticQA'}
    events = {'presented', 'sample', 'ownFieldChanged', 'escape', 'deadline'}
    records = []
    invalid = False
    for line in bytes(buffers[0]).splitlines():
        try:
            item = json.loads(line)
            assert isinstance(item, dict) and set(item) == keys
            assert item['event'] in events
            assert type(item['sample']) is int and 0 <= item['sample'] <= 60
            assert all(type(item[k]) is bool for k in keys - {'event', 'sample'})
            assert len(records) < 128
            records.append(item)
        except (ValueError, AssertionError, TypeError):
            invalid = True
    result = {'exitCode': p.returncode, 'timedOut': timed_out,
              'stdoutOverflow': overflow[0], 'stderrOverflow': overflow[1],
              'pipesClosed': not any(w.is_alive() for w in workers),
              'invalidOutput': invalid, 'records': records,
              'binarySHA256': manifest['binarySHA256']}
    (run / 'result.json').write_text(json.dumps(result, indent=2))
    print(json.dumps({'result': str(run / 'result.json'), 'exitCode': p.returncode,
                      'timedOut': timed_out, 'records': len(records), 'pipesClosed': result['pipesClosed']}), flush=True)
    sys.exit(0 if p.returncode == 0 and not timed_out and result['pipesClosed'] and not invalid and not any(overflow) else 1)
finally:
    # Covers setup/drain/report exceptions as well as the ordinary deadline path.
    if p.poll() is None:
        p.terminate()
        try:
            p.wait(timeout=2)
        except subprocess.TimeoutExpired:
            p.kill()
            p.wait(timeout=2)
