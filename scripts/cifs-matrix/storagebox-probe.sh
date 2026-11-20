#!/usr/bin/env bash
# Copyright 2024 RustFS Team
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Run the CIFS compatibility step sequence for several upstream rustfs releases
# against a real CIFS/SMB mount (for example a Storage Box). Meant to run as
# root inside a one-off python:3.12-slim container with the mount bind-mounted
# at SB_ROOT.
#
# Safety model: the only thing ever created or deleted on SB_ROOT is a single
# fresh test directory "$SB_ROOT/.cifscompat-<UTC timestamp>". Nothing else on
# SB_ROOT is read, listed (other than the names of leftover .cifscompat-*
# entries), modified or removed. Downloads, binaries and scratch live in /tmp.
#
# Environment:
#   SB_ROOT       mount root (default /sb)
#   RUSTFS_TAGS   whitespace separated upstream release tags
#                 (default "1.0.0-beta.8 1.0.2 1.0.6")
#                 (may be set empty to skip release cells)
#   PROBE_LOCAL_BIN    rustfs binary on the container-local disk (optional)
#   PROBE_LOCAL_CELLS  whitespace separated "label:KEY=VALUE" cells run with
#                      PROBE_LOCAL_BIN, e.g. "branch-content:RUSTFS_FS_IDENTITY_MODE=content"
#
# Exit codes: 0 probe ran (step FAILs are data), 3 precondition failed,
#             4 tooling/download failed.

set -euo pipefail

SB_ROOT="${SB_ROOT:-/sb}"
RUSTFS_TAGS="${RUSTFS_TAGS-1.0.0-beta.8 1.0.2 1.0.6}"
PROBE_LOCAL_BIN="${PROBE_LOCAL_BIN:-}"
PROBE_LOCAL_CELLS="${PROBE_LOCAL_CELLS:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_ROOT="/tmp/rustfs-bin"
DL_DIR="/tmp/rustfs-dl"
OUT_ROOT="/tmp/cifs-out"
SIG_RE='FileCorrupt|transaction_unknown|rename_indeterminate|erasure write quorum|Invalid argument|read_file_all|quorum unavailable'

# The probe never needs this; make sure nothing writes to it.
unset GITHUB_STEP_SUMMARY

# Cleanup state. T stays empty and CREATED=0 until the test dir was created by
# this very process, so an early abort can never remove anything.
T=""
CREATED=0
CELL_PID=""

die() {
  local code="$1"; shift
  echo "ABORT: $*" >&2
  exit "$code"
}

# Print the filesystem type of the mount whose mount point is the longest
# prefix of $1 (read from /proc/mounts).
fstype_of() {
  awk -v p="$1" '
    { m = $2; gsub(/\\040/, " ", m)
      if (p == m || index(p, (m == "/" ? "/" : m "/")) == 1) {
        if (length(m) > best) { best = length(m); t = $3 }
      } }
    END { if (t != "") print t }' /proc/mounts
}

# Kill the running cell and any rustfs started from our /tmp binaries.
kill_children() {
  local pid exe i
  if [[ -n "$CELL_PID" ]] && kill -0 "$CELL_PID" 2>/dev/null; then
    kill -TERM "$CELL_PID" 2>/dev/null || true
    # The cell's own cleanup waits up to 30s for rustfs to stop.
    for i in $(seq 1 40); do
      kill -0 "$CELL_PID" 2>/dev/null || break
      sleep 1
    done
    kill -KILL "$CELL_PID" 2>/dev/null || true
  fi
  CELL_PID=""
  for pid in /proc/[0-9]*; do
    pid="${pid#/proc/}"
    exe="$(readlink "/proc/$pid/exe" 2>/dev/null || true)"
    if [[ "$exe" == "$BIN_ROOT"/*/rustfs ]]; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  done
}

finish() {
  local rc=$?
  set +e
  trap - EXIT
  kill_children

  # Remove the test dir only if this process created it AND its path is
  # exactly "$SB_ROOT/.cifscompat-<YYYYmmddTHHMMSSZ>" (no other depth, no
  # other name). Anything else is left alone.
  local removed=no i
  if [[ "$CREATED" == 1 && -n "$T" && "$T" == "$SB_ROOT/".cifscompat-* \
        && "${T#"$SB_ROOT"/}" =~ ^\.cifscompat-[0-9]{8}T[0-9]{6}Z$ ]]; then
    for i in 1 2 3 4 5; do
      rm -rf --one-file-system -- "$T" 2>/dev/null
      [[ -e "$T" ]] || break
      sleep 3
    done
    [[ -e "$T" ]] || removed=yes
  fi
  echo "CLEANUP test_dir_removed=$removed path=${T:-none}"

  # Names only, glob on exactly this pattern.
  if [[ -d "$SB_ROOT" ]]; then
    local -a left=()
    local e
    shopt -s nullglob
    for e in "$SB_ROOT"/.cifscompat-*; do left+=("${e##*/}"); done
    shopt -u nullglob
    echo "CLEANUP remaining_cifscompat_dirs=${#left[@]}"
    for e in "${left[@]}"; do echo "$e"; done
  else
    echo "CLEANUP remaining_cifscompat_dirs=unknown"
  fi

  # Informational only; the probe creates no loop or dm devices.
  local loops dms
  loops="$(awk '$4 ~ /^loop[0-9]+$/ {printf "%s ", $4}' /proc/partitions 2>/dev/null)"
  dms="$(awk '$4 ~ /^dm-[0-9]+$/ {printf "%s ", $4}' /proc/partitions 2>/dev/null)"
  echo "CLEANUP loop_devices=${loops:-none}"
  echo "CLEANUP dm_devices=${dms:-none}"
  echo "PROBE DONE rc=$rc"
  exit "$rc"
}

# ---------------------------------------------------------- preconditions ----
[[ "$SB_ROOT" == /* && "$SB_ROOT" != "/" ]] || die 3 "SB_ROOT must be an absolute path other than /: $SB_ROOT"
SB_ROOT="${SB_ROOT%/}"
[[ -d "$SB_ROOT" ]] || die 3 "SB_ROOT is not a directory: $SB_ROOT"
SB_REAL="$(readlink -f "$SB_ROOT")"
SB_FSTYPE="$(fstype_of "$SB_REAL" || true)"
case "$SB_FSTYPE" in
  cifs|smb3) ;;
  *) die 3 "$SB_ROOT is not on a cifs/smb3 mount (fstype='${SB_FSTYPE:-unknown}'); refusing to test a local disk" ;;
esac
echo "SB_ROOT=$SB_ROOT fstype=$SB_FSTYPE"

for tag in $RUSTFS_TAGS; do
  [[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || die 3 "invalid release tag: $tag"
done

# From here on the cleanup report runs on every exit path (TERM/INT go through
# exit so the EXIT trap is the single cleanup path).
trap finish EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

T="$SB_ROOT/.cifscompat-$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -e "$T" || -L "$T" ]]; then
  T=""   # not ours: never touch it
  die 3 "test dir already exists"
fi
mkdir "$T" || { T=""; die 3 "cannot create test dir"; }
CREATED=1
echo "test dir: $T"

# ---------------------------------------------------------------- tooling ----
mkdir -p "$BIN_ROOT" "$DL_DIR" "$OUT_ROOT"

if ! python3 -m pip install --quiet --disable-pip-version-check awscli; then
  die 4 "pip install awscli failed"
fi
if ! command -v curl >/dev/null 2>&1; then
  # The cell script polls readiness with curl.
  if ! { apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends curl; } >/dev/null; then
    die 4 "curl missing and could not be installed"
  fi
fi
command -v aws >/dev/null 2>&1 || die 4 "aws cli not on PATH after install"

DL_OK=""
for tag in $RUSTFS_TAGS; do
  url="https://github.com/rustfs/rustfs/releases/download/${tag}/rustfs-linux-x86_64-gnu-v${tag}.zip"
  echo "downloading $url"
  if python3 -I - "$url" "$DL_DIR/$tag.zip" "$BIN_ROOT/$tag/rustfs" <<'PY'
import os, shutil, sys, urllib.request, zipfile

url, zpath, dest = sys.argv[1:4]
req = urllib.request.Request(url, headers={"User-Agent": "cifs-matrix-probe"})
with urllib.request.urlopen(req, timeout=120) as r, open(zpath, "wb") as f:
    shutil.copyfileobj(r, f)
with zipfile.ZipFile(zpath) as zf:
    names = [n for n in zf.namelist() if os.path.basename(n) == "rustfs" and not n.endswith("/")]
    if not names:
        sys.exit("no 'rustfs' file in archive")
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    with zf.open(names[0]) as src, open(dest, "wb") as out:
        shutil.copyfileobj(src, out)
os.chmod(dest, 0o755)
PY
  then
    DL_OK="$DL_OK $tag"
  else
    echo "WARN: download/extract failed for $tag, skipping" >&2
  fi
done
[[ -n "$DL_OK" || -z "${RUSTFS_TAGS//[[:space:]]/}" ]] || die 4 "no rustfs release could be downloaded"

# ------------------------------------------------------------------ cells ----
CELLS=""

# run_cell <label> <binary> [extra rustfs env]
run_cell() {
  local label="$1" bin="$2" extra="${3:-}" out="$OUT_ROOT/$1"
  rm -rf -- "$out"
  mkdir "$T/$label"
  echo "=== cell $label ==="
  CELL_DATA_DIR="$T/$label" RUSTFS_EXTRA_ENV="$extra" timeout 900     bash "$SCRIPT_DIR/run-matrix-cell.sh" "$label" external "$bin" "$out" &
  CELL_PID=$!
  wait "$CELL_PID" || echo "cell $label exited non-zero (data, not a probe failure)"
  CELL_PID=""
  CELLS="$CELLS $label"

  echo "=== signatures $label ==="
  if [[ -f "$out/rustfs.log" ]]; then
    { grep -E "$SIG_RE" "$out/rustfs.log" | head -n 15 | cut -c1-700; } || true
  fi
  [[ -f "$out/steps.tsv" ]] && tail -n 5 "$out/steps.tsv" || true
}

for tag in $DL_OK; do
  run_cell "release-$tag" "$BIN_ROOT/$tag/rustfs"
done

# Optional cells for a binary the caller placed on the container-local disk.
if [[ -n "$PROBE_LOCAL_BIN" ]]; then
  for cell in $PROBE_LOCAL_CELLS; do
    run_cell "${cell%%:*}" "$PROBE_LOCAL_BIN" "${cell#*:}"
  done
fi

# ---------------------------------------------------------------- summary ----
echo "=== SUMMARY ==="
printf '%-24s %s
' cell "s1   s2   s3   s4   s5   s6"
for label in $CELLS; do
  f="$OUT_ROOT/$label/steps.tsv"
  line=""
  for id in 1 2 3 4 5 6; do
    st="-"
    if [[ -f "$f" ]]; then
      st="$(awk -F'	' -v i="$id" '$1 == i {print $3; exit}' "$f")"
      st="${st:--}"
    fi
    line+="$(printf '%-4s ' "$st")"
  done
  printf '%-24s %s
' "$label" "$line"
done

exit 0
