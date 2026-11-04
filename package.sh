#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
if [ "${1:-}" != "--no-build" ]; then bash "$project_dir/build.sh"; fi
bundle="$project_dir/dist/Codex Pulse.app"
stage="$(mktemp -d /private/tmp/codex-pulse-package.XXXXXX)"
trap 'rm -rf "$stage"' EXIT
ditto --norsrc --noextattr --noacl "$bundle" "$stage/Codex Pulse.app"
codesign --verify --deep --strict "$stage/Codex Pulse.app"
ln -s /Applications "$stage/Applications"
cp -X "$project_dir/KULLANIM.md" "$stage/BENI-OKU.md"
hdiutil create -ov -volname "Codex Pulse 1.1" -srcfolder "$stage" -format UDZO \
    "$project_dir/dist/Codex-Pulse-1.1.0-universal.dmg"
python3 - "$project_dir" <<'PY'
from pathlib import Path
import hashlib
import json
import sys
import zipfile

root = Path(sys.argv[1])
source = root / 'dist/Codex-Pulse-1.1.0-source.zip'
files = ['App.swift', 'Icon.swift', 'backend.py', 'Info.plist', 'build.sh', 'package.sh',
         'KULLANIM.md', 'README.md', 'LICENSE', 'CONTRIBUTING.md', '.gitignore',
         '.gitattributes', '.github/workflows/ci.yml', 'tests/test_backend.py',
         'docs/images/accounts.png', 'docs/images/settings.png', 'docs/images/history.png']
with zipfile.ZipFile(source, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
    for name in files:
        archive.write(root / name, 'CodexPulse/' + name)
manifest = {'version': '1.1.0', 'architectures': ['arm64', 'x86_64'], 'macOS': '13+', 'files': []}
for filename in ['Codex-Pulse-1.1.0-universal.dmg', source.name]:
    data = (root / 'dist' / filename).read_bytes()
    manifest['files'].append({'name': filename, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
(root / 'dist/release.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(manifest, indent=2))
PY
