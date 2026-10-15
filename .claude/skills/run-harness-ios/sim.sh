#!/usr/bin/env bash
# Build, install and drive Harness + Harness Keyboard on an iOS 26 simulator (macOS + Xcode 26 only).
# Run from the repo root:  .claude/skills/run-harness-ios/sim.sh <command> [args]
# State and output live in .build/harness-sim/ (gitignored).
set -euo pipefail

SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SKILL/../../.." && pwd)"
OUT="$ROOT/.build/harness-sim"
DD="$OUT/DerivedData"
SHOTS="$OUT/shots"
APP_ID=org.harness.ios
KBD_ID=org.harness.ios.keyboard
GROUP_ID=group.org.harness.ios
DEVICE_NAME="${HARNESS_SIM_NAME:-Harness iPhone}"
mkdir -p "$OUT" "$SHOTS"

log() { printf '\033[1m== %s\033[0m\n' "$*" >&2; }
udid() {
  [[ -f "$OUT/udid" ]] || { echo "no simulator yet: run '$0 boot'" >&2; exit 1; }
  cat "$OUT/udid"
}
device_dir() { echo "$HOME/Library/Developer/CoreSimulator/Devices/$(udid)"; }
xcb() { # xcodebuild with readable output; full log in $OUT/<name>.log
  local name=$1; shift
  log "xcodebuild $name (log: $OUT/$name.log)"
  if ! xcodebuild "$@" >"$OUT/$name.log" 2>&1; then
    grep -E 'error:|\*\* .* FAILED|Testing failed' "$OUT/$name.log" | cut -c1-400 | sort -u | head -40 >&2 || true
    return 1
  fi
  grep -E '\*\* .* SUCCEEDED|Executed [0-9]+ test' "$OUT/$name.log" | tail -3 >&2 || true
}

cmd_boot() { # boot [device type name]: create (once) and boot a dedicated iOS 26 simulator
  local type_name="${1:-iPhone 17 Pro}"
  local id
  id=$(xcrun simctl list devices -j | python3 -c '
import json, sys
name = sys.argv[1]
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if "iOS-26" in runtime:
        for d in devices:
            if d["name"] == name and d.get("isAvailable", True): print(d["udid"]); raise SystemExit' "$DEVICE_NAME")
  if [[ -z "$id" ]]; then
    local runtime type
    runtime=$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
rs = [r for r in json.load(sys.stdin)["runtimes"] if r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-26") and r["isAvailable"]]
rs.sort(key=lambda r: [int(x) for x in r["version"].split(".")])
print(rs[-1]["identifier"] if rs else "")')
    [[ -n "$runtime" ]] || { echo "no iOS 26 simulator runtime installed (xcodebuild -downloadPlatform iOS)" >&2; exit 1; }
    type=$(xcrun simctl list devicetypes -j | python3 -c '
import json, sys
want = sys.argv[1]
types = [t for t in json.load(sys.stdin)["devicetypes"] if t["name"].startswith("iPhone")]
match = [t for t in types if t["name"] == want] or types[-1:]
print(match[0]["identifier"])' "$type_name")
    id=$(xcrun simctl create "$DEVICE_NAME" "$type" "$runtime")
    log "created $DEVICE_NAME ($type, $runtime): $id"
  fi
  echo "$id" >"$OUT/udid"
  # A connected hardware keyboard hides every software keyboard, ours included.
  defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false
  xcrun simctl boot "$id" 2>/dev/null || true
  xcrun simctl bootstatus "$id" -b >/dev/null
  log "booted $DEVICE_NAME $id"
}

cmd_build() { # build [--product-ids id,id]: Harness.app + HarnessKeyboard.appex for the simulator, ad-hoc signed
  local ids=""
  [[ "${1:-}" == "--product-ids" ]] && ids="$2"
  # Ad-hoc "-" signing (not CODE_SIGNING_ALLOWED=NO) keeps the entitlements, so the App Group works.
  xcb build-harness -project "$ROOT/iOS/Harness.xcodeproj" -scheme Harness -configuration Debug \
    -destination "id=$(udid)" -derivedDataPath "$DD" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= build
  local app="$DD/Build/Products/Debug-iphonesimulator/Harness.app"
  if [[ -n "$ids" ]]; then
    plutil -replace HarnessSubscriptionProductIDs -json "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1].split(",")))' "$ids")" "$app/Info.plist"
    codesign --force --sign - --preserve-metadata=entitlements --timestamp=none "$app"
    log "HarnessSubscriptionProductIDs = $ids"
  fi
  echo "$app"
}

cmd_install() { # install: Harness (with the keyboard inside) and FieldLab if built
  local app="$DD/Build/Products/Debug-iphonesimulator/Harness.app"
  xcrun simctl install "$(udid)" "$app"
  local lab="$OUT/DriverData/Build/Products/Debug-iphonesimulator/FieldLab.app"
  [[ -d "$lab" ]] && xcrun simctl install "$(udid)" "$lab"
  log "installed"
}

cmd_entitlements() { # entitlements: prove the App Group survives the ad-hoc build
  local app="$DD/Build/Products/Debug-iphonesimulator/Harness.app" bin
  # Simulator builds carry entitlements in a Mach-O section, not the (ad-hoc) signature.
  for bin in "$app/Harness" "$app/PlugIns/HarnessKeyboard.appex/HarnessKeyboard"; do
    echo "$(basename "$bin") entitlements section: $(strings -a "$bin" | grep -o 'group\.org\.harness\.ios' | sort -u)"
  done
  echo "group container: $(xcrun simctl get_app_container "$(udid)" "$APP_ID" "$GROUP_ID")"
}

cmd_launch() { # launch [url]: start Harness, or open a harness:// link
  if [[ -n "${1:-}" ]]; then xcrun simctl openurl "$(udid)" "$1"; else xcrun simctl launch "$(udid)" "$APP_ID"; fi
}

cmd_shot() { # shot <name>: screenshot to .build/harness-sim/shots/<name>.png
  xcrun simctl io "$(udid)" screenshot "$SHOTS/$1.png" >/dev/null 2>&1
  echo "$SHOTS/$1.png"
}

cmd_driver() { # driver: generate and build FieldLab + KeyboardDriverUITests
  python3 "$SKILL/driver/gen.py"
  xcb build-driver -project "$SKILL/driver/KeyboardDriver.xcodeproj" -scheme KeyboardDriver \
    -destination "id=$(udid)" -derivedDataPath "$OUT/DriverData" build-for-testing
  xcrun simctl install "$(udid)" "$OUT/DriverData/Build/Products/Debug-iphonesimulator/FieldLab.app"
}

cmd_test() { # test <Class[/method]>... [-- KEY=VALUE...]: run UI tests, export screenshots
  local only=() env=()
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--" ]]; then shift; env=("$@"); break; fi
    only+=("-only-testing:KeyboardDriverUITests/$1"); shift
  done
  local name
  name="$(date +%H%M%S)-$(echo "${only[0]#*/}" | tr '/' '-')"
  local result="$OUT/results/$name.xcresult"
  mkdir -p "$OUT/results"
  local status=0
  # TEST_RUNNER_<KEY> reaches the test process as <KEY>.
  env ${env[@]+"${env[@]/#/TEST_RUNNER_}"} xcodebuild -project "$SKILL/driver/KeyboardDriver.xcodeproj" -scheme KeyboardDriver \
    -destination "id=$(udid)" -derivedDataPath "$OUT/DriverData" -resultBundlePath "$result" \
    "${only[@]}" test-without-building >"$OUT/test-$name.log" 2>&1 || status=$?
  grep -E "Test Case .* (passed|failed)|error: -|XCTAssert|NOTE:" "$OUT/test-$name.log" | sed 's/^.*error: -/error: -/' | head -60 >&2 || true
  export_shots "$result"
  log "test $name: exit $status (log: $OUT/test-$name.log, result: $result)"
  return $status
}

export_shots() { # copy our named xcresult attachments to shots/ (XCTest's automatic ones are skipped)
  local tmp="$OUT/attachments-tmp"
  rm -rf "$tmp"; mkdir -p "$tmp"
  xcrun xcresulttool export attachments --path "$1" --output-path "$tmp" >/dev/null 2>&1 || return 0
  python3 - "$tmp" "$SHOTS" <<'PY2'
import json, re, shutil, sys, pathlib
src, dst = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
for test in json.loads((src / "manifest.json").read_text()):
    for a in test.get("attachments", []):
        name = a.get("suggestedHumanReadableName") or ""
        if not name[:1].islower():
            continue  # "UI Snapshot …", "Debug description …", "Synthesized Event …"
        name = re.sub(r"_\d+_[0-9A-F-]{36}", "", name)
        name = re.sub(r'[^A-Za-z0-9._-]', "_", name)
        shutil.copy(src / a["exportedFileName"], dst / name)
        print("  shot:", name)
PY2
}

cmd_keyboard_prefs() { # keyboard-prefs: add Harness to AppleKeyboards with defaults, then reboot (no Settings UI)
  local id; id=$(udid)
  echo "AppleKeyboards before: $(xcrun simctl spawn "$id" defaults read -g AppleKeyboards 2>&1 | tr -s ' \n' ' ')"
  xcrun simctl spawn "$id" defaults write -g AppleKeyboards -array "en_US@sw=QWERTY;hw=Automatic" "$KBD_ID"
  xcrun simctl spawn "$id" defaults write -g AppleKeyboardsExpanded -int 1
  xcrun simctl shutdown "$id"; xcrun simctl boot "$id"; xcrun simctl bootstatus "$id" -b >/dev/null
  echo "AppleKeyboards after reboot: $(xcrun simctl spawn "$id" defaults read -g AppleKeyboards 2>&1 | tr -s ' \n' ' ')"
}

cmd_keyboard() { # keyboard [--full-access]: enable Harness in Settings > General > Keyboard > Keyboards
  local fa=0
  [[ "${1:-}" == "--full-access" ]] && fa=1
  cmd_test SettingsTests/testEnableHarnessKeyboard -- "FULL_ACCESS=$fa"
}

cmd_prefs_snapshot() { # prefs-snapshot <tag>: every plist under the device's data dir, as text
  local dir="$OUT/prefs-$1"; rm -rf "$dir"; mkdir -p "$dir"
  (cd "$(device_dir)/data" && find . -name '*.plist' -not -path './Containers/Bundle/*' -size -512k) | while read -r f; do
    mkdir -p "$dir/$(dirname "$f")"
    plutil -p "$(device_dir)/data/$f" 2>/dev/null | grep -v CFKeyedArchiverUID >"$dir/$f.txt" || true
  done
  sqlite3 "$(device_dir)/data/Library/TCC/TCC.db" 'select service, client, client_type, auth_value, auth_reason from access' >"$dir/TCC.txt" 2>&1 || true
  echo "$dir"
}

cmd_prefs_diff() { # prefs-diff <tagA> <tagB>
  diff -ru "$OUT/prefs-$1" "$OUT/prefs-$2" || true
}

cmd_ci() { # ci: everything, in order (what .github/workflows/simulator-drive.yml runs)
  cmd_boot
  cmd_build --product-ids org.harness.ios.speak.monthly
  cmd_install
  cmd_entitlements || true
  cmd_driver
  cmd_launch; sleep 5; cmd_shot app-01-launch
  echo "simctl StoreKit commands: $(xcrun simctl help 2>&1 | grep -i -E 'store|purchase' | tr -s ' ' | tr '\n' ';')"
  local failed=0
  cmd_prefs_snapshot before >/dev/null
  cmd_keyboard_prefs || failed=1
  cmd_test TypingLayerTests || failed=1
  cmd_test FullAccessTests/testDictationPanelReflectsFullAccess -- EXPECT_FULL_ACCESS=0 || failed=1
  cmd_prefs_snapshot keyboard >/dev/null
  cmd_keyboard --full-access || failed=1
  cmd_prefs_snapshot fullaccess >/dev/null
  cmd_prefs_diff keyboard fullaccess >"$OUT/prefs-diff-fullaccess.txt"
  cmd_prefs_diff before keyboard >"$OUT/prefs-diff-keyboard.txt"
  cmd_test FullAccessTests -- EXPECT_FULL_ACCESS=1 || failed=1
  cmd_test SubscriptionTests || failed=1
  return $failed
}

usage() { echo "usage: $0 <command>  (macOS + Xcode 26)"; grep -E '^cmd_[a-z_]+\(\) \{ #' "$0" | sed -E 's/^cmd_[a-z_]+\(\) \{ # /  /'; }
c="${1:-}"; shift || true
case "$c" in
  ""|-h|--help|help) usage ;;
  *) "cmd_${c//-/_}" "$@" ;;
esac
