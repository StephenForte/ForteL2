#!/usr/bin/env bash
# Assemble a static public pipeline viewer from committed constants only.
# Does not source lib.sh, does not load .env / .env.sepolia, and never reads
# viewer/config.js (that file may hold a private QuickNode L1 URL).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/viewer"
OUT="${PUBLIC_VIEWER_OUT:-$SRC/public}"
CONFIG_PUBLIC="$SRC/config.public.js"
CSP_FILE="$SRC/public.csp"

if [[ -z "$OUT" ]]; then
  echo "ERROR: PUBLIC_VIEWER_OUT is empty" >&2
  exit 1
fi
if [[ ! -f "$CONFIG_PUBLIC" ]]; then
  echo "ERROR: missing $CONFIG_PUBLIC" >&2
  exit 1
fi
if [[ ! -f "$CSP_FILE" ]]; then
  echo "ERROR: missing $CSP_FILE" >&2
  exit 1
fi

# Resolve OUT before any rm. Never rm -rf a pre-existing directory this
# script did not create: dest must be absent, empty, or a previous public
# bundle (marked by Content-Security-Policy.txt). Also refuse SRC/ROOT
# (and any parent of SRC) even when empty. Must not depend on gitignored
# viewer/config.js (absent in CI/Render clones).
ROOT_ABS="$(cd "$ROOT" && pwd)"
SRC_ABS="$(cd "$SRC" && pwd)"
OUT_PARENT="$(dirname "$OUT")"
mkdir -p "$OUT_PARENT"
OUT="$(cd "$OUT_PARENT" && pwd)/$(basename "$OUT")"
# Collapse trailing /. so PUBLIC_VIEWER_OUT=. matches ROOT_ABS.
if [[ -d "$OUT" ]]; then
  OUT="$(cd "$OUT" && pwd)"
fi
if [[ "$OUT" == "$SRC_ABS" || "$OUT" == "$ROOT_ABS" ]]; then
  echo "ERROR: refusing to write the public bundle over $OUT" >&2
  exit 1
fi
case "$SRC_ABS" in
  "$OUT"/*)
    echo "ERROR: refusing PUBLIC_VIEWER_OUT=$OUT (would delete $SRC_ABS)" >&2
    exit 1
    ;;
esac
if [[ -e "$OUT" ]]; then
  if [[ ! -d "$OUT" ]]; then
    echo "ERROR: refusing PUBLIC_VIEWER_OUT=$OUT (not a directory)" >&2
    exit 1
  fi
  if [[ -n "$(ls -A "$OUT")" && ! -f "$OUT/Content-Security-Policy.txt" ]]; then
    echo "ERROR: refusing to rm -rf $OUT (not a public-viewer output dir)" >&2
    echo "  target must be absent, empty, or contain Content-Security-Policy.txt" >&2
    exit 1
  fi
fi

rm -rf "$OUT"
mkdir -p "$OUT"
# Marker first so a crashed rebuild stays eligible for regeneration.
cp "$CSP_FILE" "$OUT/Content-Security-Policy.txt"
mkdir -p "$OUT/fonts" "$OUT/vendor"

cp "$SRC/index.html" "$SRC/app.js" "$SRC/lib.js" "$SRC/styles.css" "$OUT/"
cp "$SRC/fonts/fonts.css" "$OUT/fonts/"
# Fonts are binary; copy if present so the hosted page matches local typography.
for font in "$SRC/fonts/"*.ttf; do
  [[ -f "$font" ]] && cp "$font" "$OUT/fonts/"
done
cp "$SRC/vendor/ethers-6.13.7.min.js" "$SRC/vendor/README.md" "$OUT/vendor/"
cp "$CONFIG_PUBLIC" "$OUT/config.js"

CSP="$(tr -d '\n' < "$CSP_FILE")"
# Inject a complete meta CSP into the public copy only. Local index.html stays
# header-only so serve-viewer.sh CSP is not AND-combined with a meta policy.
python3 - "$OUT/index.html" "$CSP" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
csp = sys.argv[2]
html = path.read_text()
needle = '<meta charset="utf-8" />'
meta = (
    needle
    + '\n  <meta http-equiv="Content-Security-Policy" content="'
    + csp.replace('"', "&quot;")
    + '" />'
)
if needle not in html:
    raise SystemExit("ERROR: index.html charset marker not found")
path.write_text(html.replace(needle, meta, 1))
PY

# Origin guard: first-party files only (vendor ethers embeds explorer URLs).
python3 - "$OUT" <<'PY'
import pathlib, sys, re
from urllib.parse import urlparse

out = pathlib.Path(sys.argv[1])
# Same three origins as viewer/lib.js PUBLIC_VIEWER_ALLOWED_ORIGINS (D-0047).
# Unit tests assert config.public.js and this list cannot drift.

ALLOWED = {
    "https://fortel2-replica-rpc.onrender.com",
    "https://fortel2-sequencer-rpc.onrender.com",
    "https://ethereum-sepolia-rpc.publicnode.com",
}

def origins(text: str):
    found = set()
    for raw in re.findall(r"https?://[^\s\"'\\<>]+", text, flags=re.I):
        cleaned = re.sub(r"[),.;]+$", "", raw)
        try:
            u = urlparse(cleaned)
        except Exception:
            continue
        if u.scheme in ("http", "https") and u.netloc:
            found.add(f"{u.scheme}://{u.netloc}")
    return found

unexpected = {}
first_party = []
for path in sorted(out.rglob("*")):
    if not path.is_file():
        continue
    rel = path.relative_to(out).as_posix()
    if rel.startswith("vendor/"):
        continue
    if path.suffix.lower() not in {".js", ".html", ".css", ".txt", ".csp"}:
        continue
    first_party.append(path)
    text = path.read_text(errors="replace")
    extra = origins(text) - ALLOWED
    if extra:
        unexpected[rel] = sorted(extra)

config_text = (out / "config.js").read_text()
config_origins = origins(config_text)
if config_origins != ALLOWED:
    print("ERROR: public config.js origins are not exactly the D-0047 allowlist", file=sys.stderr)
    print(f"  found: {sorted(config_origins)}", file=sys.stderr)
    sys.exit(1)

if unexpected:
    print("ERROR: public bundle contains origins outside the D-0047 allowlist", file=sys.stderr)
    for rel, extras in unexpected.items():
        print(f"  {rel}: {extras}", file=sys.stderr)
    sys.exit(1)

print(f"Public viewer origin allowlist OK ({len(first_party)} first-party files)")
PY

echo "Wrote $OUT (config from config.public.js; local viewer/config.js not read)"
echo "  CSP: $OUT/Content-Security-Policy.txt"
