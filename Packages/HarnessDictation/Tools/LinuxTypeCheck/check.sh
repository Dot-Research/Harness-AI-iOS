#!/bin/bash
# Type-checks the whole package on Linux (no Apple SDK) against interface stubs of Apple frameworks.
# Catches wrong names, types, bindings, closure shapes, access levels and actor isolation.
# The Harness app itself is compiled by the macOS CI job (.github/workflows/macos.yml).
# It cannot catch layout or runtime behavior; build in Xcode and run docs/QA_CHECKLIST.md for that.
# On macOS, the same checks run with distinctly named stand-ins to avoid SDK module collisions.
#
#   Tools/LinuxTypeCheck/check.sh          # Swift 5 mode (as the real package builds)
#   Tools/LinuxTypeCheck/check.sh strict   # engine and logic modules with strict concurrency
#
# Two rewrites are applied to copies, for Objective-C-only syntax Linux can't compile:
#   HarnessKeyboardViewController: #selector(X) -> _selector(X)   (X stays a checked method reference)
#   HostAppOpener: drops @convention(c) from one typealias
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$(cd "$HERE/../.." && pwd)"
WORK="${TMPDIR:-/tmp}/harness-linux-typecheck"
if [ "$(uname -s)" = "Darwin" ]; then WORK="${TMPDIR:-/tmp}/harness-macos-typecheck"; fi
mkdir -p "$WORK"
# Fresh copy of the stubs each run; keep .build so repeat runs are incremental.
find "$WORK" -mindepth 1 -maxdepth 1 ! -name .build -exec rm -rf {} +
(cd "$HERE" && tar cf - --exclude=.build --exclude=check.sh .) | (cd "$WORK" && tar xf -)
[ "${1:-}" = "strict" ] && cp "$WORK/Package.strict.swift" "$WORK/Package.swift"
cd "$WORK"

copy() {  # copy a source file, removing a surrounding #if os(iOS) ... #endif
python3 - "$1" "$2" <<'PY'
import sys
s = open(sys.argv[1]).read().strip('\n').split('\n')
if s[0].strip() == '#if os(iOS)':
    assert s[-1].strip() == '#endif', sys.argv[1]
    s = s[1:-1]
open(sys.argv[2], 'w').write('\n'.join(s) + '\n')
PY
}
for t in DictationCore DictationEngine KeyboardLogic HostLogic HarnessKeyboardKit DictationAppKit KeyboardExtension; do
    mkdir -p "Sources/$t"; rm -f "Sources/$t"/*.swift
done
cp "$SRC"/Sources/DictationCore/*.swift Sources/DictationCore/
cp Stubs/DictationEngine/*.swift Sources/DictationEngine/
for f in AppGroupBridge AudioCapture AudioGate Services Transcribers AppleTextRewriter DictationInstructionsStore; do copy "$SRC/Sources/DictationEngine/$f.swift" "Sources/DictationEngine/$f.swift"; done
cp Stubs/KeyboardLogic/*.swift Sources/KeyboardLogic/
for f in KeyboardBridgeClient TextProxyEditor KeyboardViewModel; do copy "$SRC/Sources/HarnessKeyboardKit/$f.swift" "Sources/KeyboardLogic/$f.swift"; done
copy "$SRC/Sources/DictationAppKit/DictationHost.swift" Sources/HostLogic/DictationHost.swift
for f in "$SRC"/Sources/HarnessKeyboardKit/*.swift; do copy "$f" "Sources/HarnessKeyboardKit/$(basename "$f")"; done
for f in "$SRC"/Sources/DictationAppKit/*.swift; do copy "$f" "Sources/DictationAppKit/$(basename "$f")"; done
python3 - <<'PY'
from pathlib import Path
for path, old, new in [
    (Path("Sources/HarnessKeyboardKit/HarnessKeyboardViewController.swift"), "#selector(", "_selector("),
    (Path("Sources/HarnessKeyboardKit/HostAppOpener.swift"), "@convention(c) ", ""),
]:
    path.write_text(path.read_text().replace(old, new))
PY
# The real keyboard extension target in this repo (iOS/HarnessKeyboard), when present.
REPO="$(cd "$SRC/../.." && pwd)"
[ -f "$REPO/iOS/HarnessKeyboard/KeyboardViewController.swift" ] && cp "$REPO/iOS/HarnessKeyboard/KeyboardViewController.swift" Sources/KeyboardExtension/

# On macOS, Foundation's own overlays import real Apple frameworks. Giving the stand-ins
# distinct names avoids shadowing those SDK modules while preserving every checked API shape.
if [ "$(uname -s)" = "Darwin" ]; then
    python3 - <<'PY'
from pathlib import Path
import re
names = ["AVFoundation", "Speech", "FoundationModels", "Network", "Combine", "UIKit", "ObjectiveC", "SwiftUI", "UniformTypeIdentifiers"]
manifest = Path("Package.swift")
source = manifest.read_text()
for name in names:
    source = source.replace(f'"{name}"', f'"HarnessStub{name}"')
    Path(f"Sources/{name}").rename(f"Sources/HarnessStub{name}")
manifest.write_text(source)
for path in Path("Sources").rglob("*.swift"):
    source = path.read_text()
    for name in names:
        if path.parent.name != "HarnessStubObjectiveC" or name != "ObjectiveC":
            source = re.sub(r'\bimport ' + name + r'\b', 'import HarnessStub' + name, source)
        source = re.sub(r'\b' + name + r'\.', 'HarnessStub' + name + '.', source)
        source = source.replace(f'canImport({name})', f'canImport(HarnessStub{name})')
    if path.parent.name != "HarnessStubCombine":
        # Foundation re-exports native Combine on Apple hosts; choose the intended stand-in
        # explicitly rather than allowing overload lookup to bind to an SDK implementation.
        for symbol in ["ObservableObject", "Published", "AnyCancellable", "Publisher"]:
            source = re.sub(r'(?<![\w.])' + symbol + r'\b', 'HarnessStubCombine.' + symbol, source)
    path.write_text(source)
PY
fi

build_status=0
out="$(swift build 2>&1)" || build_status=$?
issues="$(grep -E 'error:|warning:' <<<"$out" | grep -vE '/Sources/(HarnessStub)?(AVFoundation|Speech|Combine|UIKit|Network|FoundationModels|SwiftUI|ObjectiveC|UniformTypeIdentifiers)/' | sort -u || true)"
if [ -n "$issues" ]; then echo "$issues"; exit 1; fi
if [ "$build_status" -ne 0 ]; then echo "$out"; exit "$build_status"; fi
tail -1 <<<"$out"
