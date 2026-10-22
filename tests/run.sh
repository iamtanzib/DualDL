#!/bin/bash
# DualDL test suite. Run it before every build:
#
#   tests/run.sh             everything that needs no internet (~2 min)
#   tests/run.sh --network   also real YouTube/Drive downloads over both lines
#
# It never touches the installed app: its own temp folder, its own port for the
# link server, its own settings domain. UI renders land in build/snapshots for a look.
set -u
cd "$(dirname "$0")/.."
NETWORK=0
[ "${1:-}" = "--network" ] && NETWORK=1
W=$(mktemp -d -t dualdl-tests)
SRV_PID=""
cleanup() {
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
  pkill -f "$W/" 2>/dev/null
  pkill -f "turbo.py --port 5199" 2>/dev/null
  for d in dualdl-test-manager dualdl-test-snapshots; do defaults delete "$d" >/dev/null 2>&1; done
  rm -rf "$W"
}
trap cleanup EXIT
FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILED=1; }
SWIFTC=(swiftc -swift-version 5 -target arm64-apple-macos14.0)
LIB=(mac/Sources/{Manager,Server,Engine,WiFi,Tools,Preview,Turbo}.swift)

echo "== Python engine"
for f in engine/*.py tests/*.py; do
  python3 -m py_compile "$f" 2>/dev/null && pass "compiles: $f" || fail "compiles: $f"
done
mkdir -p "$W/unzip" && python3 tests/unzip_test.py "$W/unzip" || FAILED=1
mkdir -p "$W/turbo" && python3 tests/turbo_test.py "$W/turbo" || FAILED=1
mkdir -p "$W/convert" && python3 tests/convert_test.py "$W/convert" || FAILED=1
mkdir -p "$W/robust" && python3 tests/robust_test.py "$W/robust" || FAILED=1

echo "== App compiles"
if "${SWIFTC[@]}" -O -parse-as-library mac/Sources/*.swift -o "$W/DualDL" 2>"$W/swift.log"; then
  pass "app builds"
else
  grep error "$W/swift.log"; fail "app builds"
fi

echo "== Download manager over loopback (no internet)"
S="$W/mgr/srv"
mkdir -p "$S/expected/Holiday Videos/sub" "$W/mgr/home"
for f in a b c d; do head -c $((24 * 1048576)) /dev/urandom > "$S/$f.bin"; done
python3 - "$S" <<'EOF'
import os, sys, zipfile
S = sys.argv[1]; root = os.path.join(S, "expected")
for n in "xyz":
    with open(os.path.join(root, "Holiday Videos", n + ".mov"), "wb") as f: f.write(os.urandom(3_000_000))
with open(os.path.join(root, "Holiday Videos", "sub", "note ✓.txt"), "w") as f: f.write("hi")
parts = {"001": ["x.mov"], "002": ["y.mov", "sub/note ✓.txt"], "003": ["z.mov"]}
for n, files in parts.items():
    with zipfile.ZipFile(os.path.join(S, "Holiday Videos -20260101T120000Z-1-%s.zip" % n), "w") as z:
        for f in files: z.write(os.path.join(root, "Holiday Videos", f), "Holiday Videos/" + f)
os.makedirs(os.path.join(root, "Big"))
for n in "pq":
    with open(os.path.join(root, "Big", n + ".bin"), "wb") as f: f.write(os.urandom(4_000_000))
whole = os.path.join(S, "big.zip")
with zipfile.ZipFile(whole, "w") as z:
    for n in "pq": z.write(os.path.join(root, "Big", n + ".bin"), "Big/" + n + ".bin")
data = open(whole, "rb").read(); os.remove(whole); k = len(data) // 3 + 1
for i in range(3): open(os.path.join(S, "big.zip.%03d" % (i + 1)), "wb").write(data[i * k:(i + 1) * k])
EOF
FF=$(python3 -c "import sys;sys.path.insert(0,'engine');import tools;print(tools.tool_path('ffmpeg') or '')")
if [ -n "$FF" ]; then   # VP9 clips for the convert-from-the-app tests (skipped if this ffmpeg can't make them)
  "$FF" -hide_banner -loglevel error -f lavfi -i testsrc2=size=1280x720:rate=30 -f lavfi -i sine -t 4 \
    -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -c:a libopus -shortest "$S/clip.webm" 2>/dev/null
  "$FF" -hide_banner -loglevel error -f lavfi -i testsrc2=size=1920x1080:rate=30 -f lavfi -i sine -t 60 \
    -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -c:a libopus -shortest "$S/long.webm" 2>/dev/null
fi
python3 tests/make_drive_fixtures.py "$S"
python3 tests/range_server.py "$S" 51995 2 & SRV_PID=$!
B="$W/mgr/bin"; mkdir -p "$B"; cp engine/*.py "$B/"
cp tests/manager_test.swift "$B/main.swift"      # swiftc only runs top-level code from main.swift
if "${SWIFTC[@]}" "${LIB[@]}" "$B/main.swift" -o "$B/dualdl-test-manager" 2>"$W/mgr.log"; then
  (cd "$B" && DUALDL_HOME="$W/mgr/home" DUALDL_PORT=51996 DUALDL_TURBO_PORT=51998 \
     DUALDL_DRIVE_BASE=http://127.0.0.1:51995 DUALDL_RETRY_DELAYS=3,3,3 ./dualdl-test-manager "$W/mgr" 51995 >"$W/mgr.out" 2>/dev/null)
  rc=$?
  grep -E '^(PASS|FAIL|manager)' "$W/mgr.out"
  [ $rc = 0 ] || fail "manager tests (exit $rc)"
else
  grep error "$W/mgr.log"; fail "manager test builds"
fi
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=""

echo "== Chrome extension"
DENO="$HOME/Library/Application Support/DualDL/tools/deno"
if [ -x "$DENO" ]; then
  for f in extension/*.js; do
    "$DENO" run --no-prompt --allow-read - <<<"new Function(await Deno.readTextFile('$f'))" >/dev/null 2>&1 \
      && pass "parses: $f" || fail "parses: $f"
  done
  python3 -c "import json;json.load(open('extension/manifest.json'))" && pass "manifest is valid JSON" || fail "manifest"
  "$DENO" run --no-prompt --allow-read tests/extension_test.js extension/background.js || FAILED=1
else
  echo "SKIP extension checks (Deno not installed)"
fi

echo "== UI renders (build/snapshots)"
mkdir -p build/snapshots "$W/snap/home"
SNAPS="$(pwd)/build/snapshots"
ICON="$(pwd)/build/icon/master.png"
rm -f "$SNAPS"/*.png
cp tests/snapshots.swift "$W/snap/main.swift"
if "${SWIFTC[@]}" mac/Sources/{Manager,Server,Engine,WiFi,Tools,Preview,Turbo,Views}.swift "$W/snap/main.swift" \
     -o "$W/snap/dualdl-test-snapshots" 2>"$W/snap.log"; then
  (cd "$W/snap" && DUALDL_HOME="$W/snap/home" DUALDL_PORT=51997 DUALDL_TURBO_PORT=51999 DUALDL_SNAP_OUT="$SNAPS" DUALDL_ICON="$ICON" \
     ./dualdl-test-snapshots >/dev/null 2>&1)
  n=$(ls build/snapshots/*.png 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" -ge 14 ] && pass "rendered $n views" || fail "rendered only $n views"
else
  grep error "$W/snap.log"; fail "snapshot renderer builds"
fi

if [ $NETWORK = 1 ]; then
  echo "== Network: real downloads"
  N="$W/net"; mkdir -p "$N"
  python3 engine/dualdl.py --json -o "$N" "https://drive.google.com/file/d/1l_5RK28JRL19wpT22B-DY9We3TVXnnQQ/view" \
    | tail -1 | grep -q '"done"' && unzip -tq "$N/fcn8s_from_caffe.npz" >/dev/null && pass "Drive file over both lines" \
    || fail "Drive file over both lines"
  out=$(python3 engine/video.py --json -o "$N" --mode audio "https://www.youtube.com/watch?v=jNQXAC9IVRw" | tail -1)
  if grep -q '"done"' <<<"$out"; then pass "YouTube to MP3"
  elif grep -q "not a bot" <<<"$out"; then echo "SKIP YouTube: both lines are bot-checked right now (needs a Chrome login)"
  else fail "YouTube to MP3: $out"; fi
fi

echo
[ $FAILED = 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit $FAILED
