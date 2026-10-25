#!/bin/sh
# End-to-end tests: scripts/e2e.sh [output-dir]
# Builds a coverage-instrumented debug binary, stamps the real SDK (so AppKit runs with Liquid Glass, as shipped),
# runs `LeanShot --e2e`, and writes junit.xml plus coverage.json (istanbul json-summary) into the output dir.
set -e
cd "$(dirname "$0")/.."
OUT=${1:-build/e2e}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
swift build -Xswiftc -profile-generate -Xswiftc -profile-coverage-mapping
BIN="$OUT/LeanShot-e2e"
cp .build/debug/LeanShot "$BIN"
vtool -set-build-version macos 14.0 "$(xcrun --show-sdk-version)" -replace -output "$BIN" "$BIN"
codesign -s - --force "$BIN"
rm -f "$OUT"/*.profraw
STATUS=0
LLVM_PROFILE_FILE="$OUT/e2e-%p.profraw" "$BIN" --e2e "$OUT/junit.xml" || STATUS=$?
xcrun llvm-profdata merge -sparse "$OUT"/*.profraw -o "$OUT/e2e.profdata"
xcrun llvm-cov export -summary-only -instr-profile "$OUT/e2e.profdata" "$BIN" > "$OUT/llvm-cov.json"
# llvm-cov summary → istanbul json-summary: statements = lines; branches = code regions, because Swift emits no
# branch regions; product sources only.
python3 - "$OUT/llvm-cov.json" "$OUT/coverage.json" "$PWD/" <<'PY'
import json, sys
data, out, root = json.load(open(sys.argv[1]))["data"][0], {}, sys.argv[3]
def entry(s): return {"statements": {"covered": s["lines"]["covered"], "total": s["lines"]["count"]},
                      "branches": {"covered": s["regions"]["covered"], "total": s["regions"]["count"]}}
tests = ("EditorTests.swift", "E2ETests.swift", "Bench.swift")
files = [f for f in data["files"] if "/Sources/LeanShot/" in f["filename"] and not f["filename"].endswith(tests)]
for f in files: out[f["filename"].replace(root, "")] = entry(f["summary"])
sums = {k: {"covered": sum(f["summary"][k]["covered"] for f in files), "count": sum(f["summary"][k]["count"] for f in files)} for k in ("lines", "regions")}
out["total"] = entry(sums)
json.dump(out, open(sys.argv[2], "w"), indent=1)
print(f"coverage: {sums['lines']['covered']}/{sums['lines']['count']} lines, {sums["regions"]["covered"]}/{sums["regions"]["count"]} regions")
PY
rm -f "$OUT"/*.profraw "$OUT/llvm-cov.json"
exit $STATUS
