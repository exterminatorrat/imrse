#!/usr/bin/env python3
"""Dependency-free provenance and resource check. No network requests."""
from pathlib import Path
import hashlib,json,re
root=Path(__file__).resolve().parents[1]
manifest=json.loads((root/"SOURCE-MANIFEST.json").read_text())
for entry in manifest["sourceFiles"]:
 name=Path(entry["path"]).name
 for path in [root/"upstream"/name,root/"web/src/components/agent-elements"/name]:
  data=path.read_bytes();digest=hashlib.sha1(b"blob "+str(len(data)).encode()+b"\0"+data).hexdigest()
  if digest!=entry["gitBlobSHA"]:raise SystemExit(f"Upstream mismatch: {path}")
source=(root/"upstream/spiral-loader-data.ts").read_text()
for name,payload in re.findall(r'export const spiral(Fast|Slow)Data = (\{.*?\});',source):
 native=root/f"native/Sources/ImrsePillUI/Resources/spiral-{name.lower()}.json"
 if json.loads(native.read_text())!=json.loads(payload):raise SystemExit(f"Asset changed: {native}")
print("PASS: exact upstream blobs and lossless native resource extraction")
