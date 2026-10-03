#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

swift test

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
for file in Sources/ImrseSettingsKit/*.swift; do
  # Parser-only pass over the UI branch as well. This does not type-check SwiftUI on Linux.
  sed -E '/^#if canImport\(/d; /^#endif$/d' "$file" > "$work/$(basename "$file")"
  swiftc -frontend -parse "$work/$(basename "$file")"
done

if grep -R -n -E 'TODO|FIXME|Your AI commands|Your words\. Elevated|wand\.and\.stars|sparkle' Sources; then
  echo "Unexpected unfinished or rejected design copy found." >&2
  exit 1
fi

printf '\nVerification complete.\n'
