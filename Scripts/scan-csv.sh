#!/bin/zsh
# CSV mine-sweeper: runs LightData's real load pipeline (delimiter detection +
# parser) over every *.csv/*.tsv under a directory and flags files whose parse
# looks WRONG — so detection bugs surface here instead of when you open the file.
#
# Heuristics flagged as suspicious:
#   - parses to a single column            (delimiter probably missed entirely)
#   - a header NAME contains , ; | or tab  (delimiter split the wrong way)
#   - >30% of headers are synthetic "Column N" (header row didn't split / ragged)
#
# Usage: Scripts/scan-csv.sh <directory> [more directories...]
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=".build/dd/Build/Products/Debug/LightData.app/Contents/MacOS/LightData"
[[ -x "$BIN" ]] || BIN="/Applications/LightData.app/Contents/MacOS/LightData"
[[ -x "$BIN" ]] || { echo "LightData binary not found — build first (Scripts/test.sh)"; exit 1; }

suspicious=0
total=0
for dir in "$@"; do
    while IFS= read -r -d '' f; do
        total=$((total+1))
        out=$("$BIN" --dump "$f" 2>/dev/null | head -3) || { echo "❌ LOAD FAILED: $f"; suspicious=$((suspicious+1)); continue; }
        verdict=$(OUT="$out" python3 - "$f" <<'EOF'
import os, sys
lines = os.environ.get("OUT", "").splitlines()
path = sys.argv[1]
if len(lines) < 3:
    print(f"❌ NO OUTPUT: {path}"); sys.exit()
summary, info, header = lines[0], lines[1], lines[2]
cols = int(summary.split(",")[1].strip().split()[0]) if "," in summary else 0
names = header.split("\t")
problems = []
if cols <= 1:
    problems.append("single column")
bad_names = [n for n in names if any(c in n for c in ",;|")]
if bad_names:
    problems.append(f"delimiter chars inside header name(s): {bad_names[:2]}")
synthetic = sum(1 for n in names if n.startswith("Column "))
if names and synthetic / len(names) > 0.3:
    problems.append(f"{synthetic}/{len(names)} synthetic 'Column N' headers")
if problems:
    print(f"⚠️  {path}\n      {summary} | {info}\n      -> " + "; ".join(problems))
EOF
)
        if [[ -n "$verdict" ]]; then
            echo "$verdict"
            suspicious=$((suspicious+1))
        fi
    done < <(find "$dir" \( -name "*.csv" -o -name "*.tsv" \) -type f -print0 2>/dev/null)
done
echo "---"
echo "scanned $total files, $suspicious suspicious"
