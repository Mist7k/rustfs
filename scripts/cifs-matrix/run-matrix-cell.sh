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

# Run one cell of the CIFS compatibility matrix: one rustfs binary on one
# filesystem flavour. Intended for a GitHub-hosted ubuntu runner (needs sudo,
# docker, aws cli, curl, python3).
#
# Usage: run-matrix-cell.sh <target> <fs> <rustfs-binary> [out-dir]
#   fs: local | cifs-noserverino | cifs-serverino | cifs-noserverino-strict
#       | external
#   external: use the existing, empty directory in CELL_DATA_DIR as the rustfs
#   data dir (e.g. a real CIFS mount). No sudo, docker or mount handling; the
#   caller owns the data dir.
#
# Optional environment:
#   RUSTFS_EXTRA_ENV   whitespace separated KEY=VALUE pairs passed to rustfs
#   CELL_WORK_DIR      scratch directory (default /mnt/cifs-matrix,
#                      /tmp/cifs-matrix for fs=external)
#   CELL_DATA_DIR      data dir, required for fs=external
#   CELL_PORT          rustfs listen port (default 9000)
#   CELL_MODE          steps (default) | crash
#   CRASH_OP           crash mode: put | overwrite | multipart | start
#   CRASH_ITERATIONS   crash mode: rounds (default 100)
#   CRASH_FAULT        crash mode: kill (default) | power
#
# Crash mode kills rustfs with SIGKILL at a random point of one operation per
# round, restarts it and checks: rustfs becomes ready again, every acknowledged
# object reads back with its sha256, an unacknowledged object is either absent
# or complete (overwrite: old or new content, never absent).
#
# CRASH_FAULT=power puts the Samba export (fs=local: the data dir) on ext4 on a
# device-mapper device and, before the kill, swaps its table to "error": every
# write that is not yet durable is lost, like a power cut on the server. Samba
# is restarted on the replayed filesystem afterwards.

set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "usage: $0 <target> <fs> <rustfs-binary> [out-dir]" >&2
  exit 2
fi

TARGET="$1"
FS="$2"
BIN="$(readlink -f "$3")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${4:-$PWD/cifs-matrix-out/${TARGET}__${FS}}"
if [[ "$FS" == external ]]; then
  WORK="${CELL_WORK_DIR:-/tmp/cifs-matrix}"
else
  WORK="${CELL_WORK_DIR:-/mnt/cifs-matrix}"
fi
EXTRA_ENV="${RUSTFS_EXTRA_ENV:-}"

PORT="${CELL_PORT:-9000}"
ENDPOINT="http://127.0.0.1:${PORT}"
ACCESS_KEY="cifsmatrixadmin"
SECRET_KEY="cifsmatrixsecret"
SMB_USER="rfs"
SMB_PASS="cifsmatrixpw"
SMB_IMAGE_TAG="cifs-matrix-samba:local"
CONTAINER="cifs-matrix-samba"
BUCKET="cifs-matrix"

EXPORT="$WORK/export"
MNT="$WORK/mnt"
TMP="$WORK/tmp"
LOG="$OUT_DIR/rustfs.log"
DATA=""

RUSTFS_PID=""
IS_CIFS=0
IS_EXTERNAL=0
CACHE_OPT=""
SERVERINO_OPT=""

case "$FS" in
  local) ;;
  cifs-noserverino)        IS_CIFS=1; CACHE_OPT="cache=none";   SERVERINO_OPT="noserverino" ;;
  cifs-serverino)          IS_CIFS=1; CACHE_OPT="cache=none";   SERVERINO_OPT="serverino" ;;
  cifs-noserverino-strict) IS_CIFS=1; CACHE_OPT="cache=strict"; SERVERINO_OPT="noserverino" ;;
  external)                IS_EXTERNAL=1 ;;
  *) echo "unknown fs: $FS" >&2; exit 2 ;;
esac

case "${CRASH_FAULT:-kill}" in
  kill|power) ;;
  *) echo "unknown CRASH_FAULT: $CRASH_FAULT" >&2; exit 2 ;;
esac

if [[ "$IS_EXTERNAL" == 1 ]]; then
  if [[ -z "${CELL_DATA_DIR:-}" || ! -d "$CELL_DATA_DIR" ]]; then
    echo "fs=external requires CELL_DATA_DIR to be an existing directory" >&2
    exit 2
  fi
  if [[ -n "$(ls -A "$CELL_DATA_DIR")" ]]; then
    echo "CELL_DATA_DIR must be empty: $CELL_DATA_DIR" >&2
    exit 2
  fi
fi

[[ -x "$BIN" ]] || { echo "rustfs binary not executable: $BIN" >&2; exit 2; }

mkdir -p "$OUT_DIR"
: > "$LOG"
: > "$OUT_DIR/steps.tsv"

log() { printf '[cell %s/%s] %s\n' "$TARGET" "$FS" "$*"; }

# ---------------------------------------------------------------- results ---
declare -A STATUS=()

# rec <step-id> <step-name> <PASS|FAIL|SKIP> [note]
rec() {
  local id="$1" name="$2" status="$3" note="${4:-}"
  note="${note//$'\t'/ }"
  note="${note//$'\r'/ }"
  note="${note//$'\n'/ | }"
  STATUS["$id"]="$status"
  printf '%s\t%s\t%s\t%s\n' "$id" "$name" "$status" "$note" >> "$OUT_DIR/steps.tsv"
  log "step $id ($name): $status ${note:+- $note}"
}

# --------------------------------------------------------------- cleanup ----
stop_rustfs() {
  [[ -n "$RUSTFS_PID" ]] || return 0
  if kill -0 "$RUSTFS_PID" 2>/dev/null; then
    kill -TERM "$RUSTFS_PID" 2>/dev/null || true
    local i
    for i in $(seq 1 30); do
      kill -0 "$RUSTFS_PID" 2>/dev/null || break
      sleep 1
    done
    kill -KILL "$RUSTFS_PID" 2>/dev/null || true
  fi
  wait "$RUSTFS_PID" 2>/dev/null || true
  RUSTFS_PID=""
}

cleanup() {
  set +e
  stop_rustfs
  if [[ "$IS_CIFS" == 1 ]]; then
    if mountpoint -q "$MNT" 2>/dev/null; then
      sudo umount "$MNT" 2>/dev/null || sudo umount -l "$MNT" 2>/dev/null
    fi
    docker rm -f "$CONTAINER" >/dev/null 2>&1
  fi
  if [[ -n "${DM_LOOP:-}" ]]; then
    sudo umount "$DM_MOUNT" 2>/dev/null
    sudo dmsetup remove "$DM_NAME" 2>/dev/null
    sudo losetup -d "$DM_LOOP" 2>/dev/null
  fi
  return 0
}
trap cleanup EXIT
trap 'exit 143' TERM INT

# ------------------------------------------------------------ filesystem ----
DM_NAME="cifs-crash-export"
DM_LOOP=""
DM_SECTORS=0
DM_MOUNT=""

# Puts $DM_MOUNT on ext4 on a device-mapper device backed by a sparse file.
setup_dm() {
  truncate -s 6G "$WORK/backing.img"
  DM_LOOP="$(sudo losetup --find --show "$WORK/backing.img")"
  DM_SECTORS="$(sudo blockdev --getsz "$DM_LOOP")"
  sudo dmsetup create "$DM_NAME" --table "0 $DM_SECTORS linear $DM_LOOP 0"
  sudo mkfs.ext4 -q "/dev/mapper/$DM_NAME"
  sudo mount "/dev/mapper/$DM_NAME" "$DM_MOUNT"
  sudo chown "$(id -u):$(id -g)" "$DM_MOUNT"
}

dm_table() {
  sudo dmsetup suspend --noflush --nolockfs "$DM_NAME"
  sudo dmsetup load "$DM_NAME" --table "$1"
  sudo dmsetup resume "$DM_NAME"
}

# From here every read and write on $DM_MOUNT fails.
power_cut() { dm_table "0 $DM_SECTORS error"; }

# Drops everything that was not yet durable and brings $DM_MOUNT back.
power_restore() {
  if [[ "$IS_CIFS" == 1 ]]; then
    sudo umount -f "$MNT" 2>/dev/null || sudo umount -l "$MNT" || return 1
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  fi
  sudo umount "$DM_MOUNT" || return 1
  dm_table "0 $DM_SECTORS linear $DM_LOOP 0" || return 1
  sudo e2fsck -p "/dev/mapper/$DM_NAME" >/dev/null 2>&1 || true
  sudo mount "/dev/mapper/$DM_NAME" "$DM_MOUNT" || return 1
  if [[ "$IS_CIFS" == 1 ]]; then samba_up || return 1; fi
  mkdir -p "$DATA"
}

setup_cifs() {
  log "installing cifs-utils"
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cifs-utils
  if ! sudo modprobe cifs; then
    log "modprobe cifs failed, installing linux-modules-extra-$(uname -r)"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "linux-modules-extra-$(uname -r)"
    sudo modprobe cifs
  fi

  log "building samba image"
  docker build -t "$SMB_IMAGE_TAG" - <<'DOCKERFILE'
FROM debian:12.11-slim
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends samba \
 && rm -rf /var/lib/apt/lists/*
DOCKERFILE

  cat > "$WORK/smb.conf" <<'SMBCONF'
[global]
   server role = standalone server
   map to guest = never
   server min protocol = SMB3
   smb ports = 445
   disable netbios = yes
   load printers = no
   printing = bsd
   printcap name = /dev/null
   log level = 1
   unix extensions = no

[data]
   path = /export
   read only = no
   valid users = rfs
SMBCONF

  samba_up
}

# Starts the samba container on $EXPORT and mounts it on $MNT.
samba_up() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker run -d --name "$CONTAINER" \
    -p 127.0.0.1:445:445 \
    -e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)" \
    -e "SMB_USER=$SMB_USER" -e "SMB_PASS=$SMB_PASS" \
    -v "$EXPORT:/export" \
    -v "$WORK/smb.conf:/etc/samba/smb.conf:ro" \
    "$SMB_IMAGE_TAG" \
    sh -c 'groupadd -g "$HOST_GID" hostgrp 2>/dev/null; useradd -M -u "$HOST_UID" -g "$HOST_GID" -s /usr/sbin/nologin "$SMB_USER" && printf "%s\n%s\n" "$SMB_PASS" "$SMB_PASS" | smbpasswd -a -s "$SMB_USER" && exec smbd --foreground --no-process-group --debug-stdout' \
    >/dev/null

  local i
  for i in $(seq 1 60); do
    if timeout 1 bash -c 'exec 3<>/dev/tcp/127.0.0.1/445' 2>/dev/null; then break; fi
    if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != "true" ]]; then
      docker logs "$CONTAINER" 2>&1 | tail -30 || true
      echo "samba container exited" >&2
      return 1
    fi
    sleep 1
  done

  local opts="username=$SMB_USER,password=$SMB_PASS,vers=3.1.1,$CACHE_OPT,soft,nounix,mapposix,nobrl,mfsymlinks,noperm,uid=$(id -u),gid=$(id -g),$SERVERINO_OPT"
  log "mounting //127.0.0.1/data on $MNT"
  # The published port accepts connections before smbd is listening inside
  # the container, so the first mount attempts can be reset.
  for i in $(seq 1 30); do
    if sudo mount -t cifs //127.0.0.1/data "$MNT" -o "$opts"; then return 0; fi
    sleep 1
  done
  docker logs "$CONTAINER" 2>&1 | tail -50 || true
  sudo dmesg 2>/dev/null | grep -i cifs | tail -30 || true
  echo "cifs mount failed" >&2
  return 1
}

# fs=external: hide the mount source and credential/address values in mount
# info; every other option stays visible.
redact_mount() {
  sed -E \
    -e 's#(^|[ \t])(//|\\\\)[^ \t]*#\1REDACTED#g' \
    -e 's/(^|[ \t,])(username|addr|ip|domain|password)=[^, \t]*/\1\2=REDACTED/g'
}

# fs=external: print the /proc/mounts line whose mount point is the longest
# prefix of $1 (fallback when findmnt is missing).
proc_mounts_for() {
  awk -v p="$1" '
    { m = $2; gsub(/\\040/, " ", m)
      if (p == m || index(p, (m == "/" ? "/" : m "/")) == 1) {
        if (length(m) > best) { best = length(m); line = $0 }
      } }
    END { if (line != "") print line }' /proc/mounts
}

prepare_fs() {
  if [[ "$IS_EXTERNAL" == 1 ]]; then
    mkdir -p "$WORK"
    rm -rf "$TMP"
    mkdir -p "$TMP"
    DATA="$CELL_DATA_DIR"
    {
      echo "fs=$FS"
      echo "data_dir=$DATA"
      echo "--- mount (redacted)"
      if command -v findmnt >/dev/null 2>&1; then
        findmnt -T "$DATA" -o TARGET,SOURCE,FSTYPE,OPTIONS 2>&1 | redact_mount || true
      else
        proc_mounts_for "$(readlink -f "$DATA")" | redact_mount || true
      fi
      echo "--- uname -r"
      uname -r
    } > "$OUT_DIR/mounts.txt"
    cat "$OUT_DIR/mounts.txt"
    return 0
  fi

  sudo mkdir -p "$WORK"
  sudo chown "$(id -u):$(id -g)" "$WORK"
  rm -rf "$EXPORT" "$MNT" "$TMP" "$WORK/local-data"
  mkdir -p "$EXPORT" "$MNT" "$TMP"

  if [[ "$IS_CIFS" == 1 ]]; then
    if [[ "${CRASH_FAULT:-kill}" == power ]]; then DM_MOUNT="$EXPORT"; setup_dm; fi
    setup_cifs
    DATA="$MNT/data"
  elif [[ "${CRASH_FAULT:-kill}" == power ]]; then
    DM_MOUNT="$WORK/local-data"
    mkdir -p "$DM_MOUNT"
    setup_dm
    DATA="$DM_MOUNT/data"
  else
    DATA="$WORK/local-data"
  fi
  mkdir -p "$DATA"

  {
    echo "fs=$FS"
    echo "data_dir=$DATA"
    echo "--- findmnt -T data_dir"
    findmnt -T "$DATA" -o TARGET,SOURCE,FSTYPE,OPTIONS || true
    if [[ "$IS_CIFS" == 1 ]]; then
      echo "--- /proc/mounts (cifs)"
      grep " $MNT cifs " /proc/mounts || true
    fi
    echo "--- uname -r"
    uname -r
  } > "$OUT_DIR/mounts.txt"
  cat "$OUT_DIR/mounts.txt"
}

# Diagnostic only: never fails the cell.
inode_probe() {
  local dir="$DATA/.inode-probe" out="$OUT_DIR/inode.txt"
  {
    mkdir -p "$dir"
    echo x > "$dir/a"
    if ln "$dir/a" "$dir/b"; then
      local sa sb
      sa="$(stat -c '%i %h' "$dir/a")"
      sb="$(stat -c '%i %h' "$dir/b")"
      echo "a: $sa"
      echo "b: $sb"
      if [[ "${sa%% *}" == "${sb%% *}" ]]; then
        echo "inodes_equal: yes"
      else
        echo "inodes_equal: no"
      fi
    else
      echo "inodes_equal: n/a (hardlink failed)"
    fi
    rm -rf "$dir"
  } > "$out" 2>&1 || true
  cat "$out"
}

# ---------------------------------------------------------------- rustfs ----
start_rustfs() {
  echo "=== $(date -u +%FT%TZ) starting rustfs ($1) ===" >> "$LOG"
  local -a extra=()
  if [[ -n "$EXTRA_ENV" ]]; then
    read -r -a extra <<< "$EXTRA_ENV"
  fi
  env \
    RUSTFS_VOLUMES="$DATA" \
    RUSTFS_ADDRESS="127.0.0.1:${PORT}" \
    RUSTFS_ACCESS_KEY="$ACCESS_KEY" \
    RUSTFS_SECRET_KEY="$SECRET_KEY" \
    RUSTFS_CONSOLE_ENABLE=false \
    RUSTFS_UNSUPPORTED_FS_POLICY=warn \
    RUSTFS_OBS_LOGGER_LEVEL=info \
    RUSTFS_OBS_LOG_STDOUT_ENABLED=true \
    "${extra[@]}" \
    "$BIN" >> "$LOG" 2>&1 &
  RUSTFS_PID=$!
}

READY_NOTE=""
# Succeeds when /health/ready answers 200. Only when that route does not exist
# (404, older releases) /health is accepted instead.
wait_ready() {
  local secs="${1:-60}" deadline code=""
  deadline=$((SECONDS + secs))
  READY_NOTE=""
  while (( SECONDS < deadline )); do
    if ! kill -0 "$RUSTFS_PID" 2>/dev/null; then
      READY_NOTE="rustfs process exited before becoming ready"
      return 1
    fi
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$ENDPOINT/health/ready" || true)"
    if [[ "$code" == "200" ]]; then READY_NOTE="ready via /health/ready"; return 0; fi
    if [[ "$code" == "404" ]]; then
      code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$ENDPOINT/health" || true)"
      if [[ "$code" == "200" ]]; then READY_NOTE="ready via /health (no /health/ready)"; return 0; fi
    fi
    sleep 1
  done
  READY_NOTE="not ready after ${secs}s (last http=${code:-none})"
  return 1
}

# ------------------------------------------------------------------ aws -----
export AWS_ACCESS_KEY_ID="$ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET_KEY"
export AWS_DEFAULT_REGION="us-east-1"
export AWS_MAX_ATTEMPTS=1
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
export AWS_PAGER=""

AWS_ERR=""
# s3api <args...>: stdout is the aws output; stderr is kept in AWS_ERR.
s3api() {
  local errf="$TMP/aws.err" rc=0
  timeout 180 aws --endpoint-url "$ENDPOINT" \
    --cli-connect-timeout 10 --cli-read-timeout 120 \
    s3api "$@" 2> "$errf" || rc=$?
  AWS_ERR="$(tr '\n' ' ' < "$errf" | cut -c1-400)"
  return "$rc"
}

sha() { sha256sum "$1" | cut -d' ' -f1; }

# get_matches <key> <expected-sha>: 0 when the downloaded object matches.
get_matches() {
  local key="$1" want="$2" f="$TMP/dl.bin"
  rm -f "$f"
  AWS_ERR=""
  s3api get-object --bucket "$BUCKET" --key "$key" "$f" >/dev/null || return 1
  [[ "$(sha "$f")" == "$want" ]]
}

# ----------------------------------------------------------------- steps ----
SHA_SIMPLE=""
SHA_KEEP=""
SHA_MP=""

step_start() {
  start_rustfs first
  if wait_ready 60; then
    rec 1 "start + ready" PASS "$READY_NOTE"
  else
    rec 1 "start + ready" FAIL "$READY_NOTE"
  fi
}

step_bucket() {
  if [[ "${STATUS[1]}" != PASS ]]; then rec 2 "create bucket" SKIP "start failed"; return 0; fi
  if s3api create-bucket --bucket "$BUCKET" >/dev/null; then
    rec 2 "create bucket" PASS
  else
    rec 2 "create bucket" FAIL "$AWS_ERR"
  fi
}

step_simple() {
  local name="simple PUT/GET sha256"
  if [[ "${STATUS[2]}" != PASS ]]; then rec 3 "$name" SKIP "no bucket"; return 0; fi
  head -c 1048576 /dev/urandom > "$TMP/simple.bin"
  head -c 1048576 /dev/urandom > "$TMP/keep.bin"
  SHA_SIMPLE="$(sha "$TMP/simple.bin")"
  SHA_KEEP="$(sha "$TMP/keep.bin")"
  if ! s3api put-object --bucket "$BUCKET" --key simple --body "$TMP/simple.bin" >/dev/null; then
    rec 3 "$name" FAIL "put simple: $AWS_ERR"; return 0
  fi
  if ! s3api put-object --bucket "$BUCKET" --key keep --body "$TMP/keep.bin" >/dev/null; then
    rec 3 "$name" FAIL "put keep: $AWS_ERR"; return 0
  fi
  if ! get_matches simple "$SHA_SIMPLE"; then
    rec 3 "$name" FAIL "get simple: ${AWS_ERR:-sha256 mismatch}"; return 0
  fi
  rec 3 "$name" PASS
}

step_multipart() {
  local name="multipart upload + GET sha256"
  if [[ "${STATUS[2]}" != PASS ]]; then rec 4 "$name" SKIP "no bucket"; return 0; fi
  local uid i etag parts="" sep=""
  if ! uid="$(s3api create-multipart-upload --bucket "$BUCKET" --key mp --query UploadId --output text)"; then
    rec 4 "$name" FAIL "create-multipart-upload: $AWS_ERR"; return 0
  fi
  : > "$TMP/mp.bin"
  for i in 1 2 3 4; do
    head -c 5242880 /dev/urandom > "$TMP/part$i.bin"
    cat "$TMP/part$i.bin" >> "$TMP/mp.bin"
    if ! etag="$(s3api upload-part --bucket "$BUCKET" --key mp --upload-id "$uid" \
        --part-number "$i" --body "$TMP/part$i.bin" --query ETag --output json)"; then
      rec 4 "$name" FAIL "upload-part $i: $AWS_ERR"
      s3api abort-multipart-upload --bucket "$BUCKET" --key mp --upload-id "$uid" >/dev/null || true
      return 0
    fi
    parts+="${sep}{\"ETag\":${etag},\"PartNumber\":${i}}"
    sep=","
  done
  printf '{"Parts":[%s]}' "$parts" > "$TMP/parts.json"
  if ! s3api complete-multipart-upload --bucket "$BUCKET" --key mp --upload-id "$uid" \
      --multipart-upload "file://$TMP/parts.json" >/dev/null; then
    rec 4 "$name" FAIL "complete-multipart-upload: $AWS_ERR"; return 0
  fi
  SHA_MP="$(sha "$TMP/mp.bin")"
  if ! get_matches mp "$SHA_MP"; then
    rec 4 "$name" FAIL "get mp: ${AWS_ERR:-sha256 mismatch}"; return 0
  fi
  rec 4 "$name" PASS
}

step_delete() {
  local name="DELETE + HEAD 404"
  if [[ "${STATUS[3]}" != PASS ]]; then rec 5 "$name" SKIP "simple object missing"; return 0; fi
  if ! s3api delete-object --bucket "$BUCKET" --key simple >/dev/null; then
    rec 5 "$name" FAIL "delete: $AWS_ERR"; return 0
  fi
  if s3api head-object --bucket "$BUCKET" --key simple >/dev/null; then
    rec 5 "$name" FAIL "HEAD still succeeds after delete"; return 0
  fi
  if [[ "$AWS_ERR" == *"404"* || "$AWS_ERR" == *"Not Found"* ]]; then
    rec 5 "$name" PASS
  else
    rec 5 "$name" FAIL "HEAD failed but not with 404: $AWS_ERR"
  fi
}

step_restart() {
  local name="restart + objects intact"
  if [[ "${STATUS[1]}" != PASS ]]; then rec 6 "$name" SKIP "start failed"; return 0; fi
  stop_rustfs
  start_rustfs restart
  if ! wait_ready 60; then rec 6 "$name" FAIL "after restart: $READY_NOTE"; return 0; fi
  local checked=""
  if [[ "${STATUS[3]}" == PASS ]]; then
    if ! get_matches keep "$SHA_KEEP"; then
      rec 6 "$name" FAIL "keep after restart: ${AWS_ERR:-sha256 mismatch}"; return 0
    fi
    checked+="keep "
  fi
  if [[ "${STATUS[4]}" == PASS ]]; then
    if ! get_matches mp "$SHA_MP"; then
      rec 6 "$name" FAIL "mp after restart: ${AWS_ERR:-sha256 mismatch}"; return 0
    fi
    checked+="mp "
  fi
  rec 6 "$name" PASS "verified: ${checked:-none (ready only)}"
}

# ------------------------------------------------------------ crash mode ----
CRASH_OP="${CRASH_OP:-put}"
CRASH_ITER="${CRASH_ITERATIONS:-100}"
CRASH_FAULT="${CRASH_FAULT:-kill}"
CRASH_TSV="$OUT_DIR/crash.tsv"
declare -A ACKED=()
N_ACKED=0
N_UNACKED_ABSENT=0
N_UNACKED_PRESENT=0
N_BAD=0
CRASH_ABORT=""

kill_rustfs() {
  [[ -n "$RUSTFS_PID" ]] || return 0
  kill -KILL "$RUSTFS_PID" 2>/dev/null || true
  wait "$RUSTFS_PID" 2>/dev/null || true
  RUSTFS_PID=""
}

now_ms() { date +%s%3N; }

# rand_ms <lo> <hi>: uniform integer in [lo, hi]
rand_ms() {
  local lo="$1" hi="$2"
  if (( hi <= lo )); then echo "$lo"; return 0; fi
  echo $(( lo + (RANDOM * 32768 + RANDOM) % (hi - lo + 1) ))
}

sleep_ms() { sleep "$(printf '%d.%03d' $(( $1 / 1000 )) $(( $1 % 1000 )))"; }

# object_state <key> <sha>...: prints absent | match:<sha> | bad:<reason>
object_state() {
  local key="$1" f="$TMP/state.bin" got want
  shift
  rm -f "$f"
  if ! s3api get-object --bucket "$BUCKET" --key "$key" "$f" >/dev/null; then
    if [[ "$AWS_ERR" == *NoSuchKey* || "$AWS_ERR" == *"(404)"* ]]; then
      echo absent
    else
      echo "bad:get failed: $AWS_ERR"
    fi
    return 0
  fi
  got="$(sha "$f")"
  for want in "$@"; do
    if [[ "$got" == "$want" ]]; then echo "match:$want"; return 0; fi
  done
  echo "bad:sha256 mismatch"
}

# crash_rec <round> <delay-ms> <acked> <state> <verdict>
crash_rec() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$CRASH_TSV"
  if [[ "$5" != ok ]]; then
    N_BAD=$((N_BAD + 1))
    log "round $1: VIOLATION delay=${2}ms acked=$3 state=$4"
  fi
}

# restart_after_kill <round>: 0 when rustfs is ready again.
restart_after_kill() {
  if [[ "$CRASH_FAULT" == power ]] && ! power_restore; then
    CRASH_ABORT="round $1: export did not come back after the power cut"
    return 1
  fi
  start_rustfs "crash round $1"
  if wait_ready 120; then return 0; fi
  CRASH_ABORT="round $1: not ready after kill: $READY_NOTE"
  return 1
}

# CLI_MS: time of a request without payload (mostly aws cli start-up).
CLI_MS=0
calibrate_cli() {
  local t0 t1
  t0="$(now_ms)"
  s3api head-bucket --bucket "$BUCKET" >/dev/null || true
  t1="$(now_ms)"
  CLI_MS=$((t1 - t0))
}

# set_window <duration-ms of one undisturbed request>
WIN_LO=0
WIN_HI=0
set_window() {
  WIN_LO=$((CLI_MS * 8 / 10))
  WIN_HI=$(( $1 * 11 / 10 ))
  log "$CRASH_OP window: ${WIN_LO}..${WIN_HI} ms"
}

# run_killed <round> <s3api args...>: runs the request in the background and
# kills rustfs after a random delay inside the window. Sets KILL_DELAY and
# KILL_ACKED. The upper bound follows the outcome so that most kills land
# before the acknowledgement instead of after it.
KILL_DELAY=0
KILL_ACKED=no
run_killed() {
  local round="$1" client rc=0
  shift
  echo "=== $(date -u +%FT%TZ) crash round $round ($CRASH_OP, $CRASH_FAULT) ===" >> "$LOG"
  KILL_DELAY="$(rand_ms "$WIN_LO" "$WIN_HI")"
  ( s3api "$@" >/dev/null ) &
  client=$!
  sleep_ms "$KILL_DELAY"
  if [[ "$CRASH_FAULT" == power ]]; then power_cut; fi
  kill_rustfs
  wait "$client" || rc=$?
  if [[ "$rc" == 0 ]]; then
    KILL_ACKED=yes
    WIN_HI=$((WIN_HI * 97 / 100))
  else
    KILL_ACKED=no
    WIN_HI=$((WIN_HI * 101 / 100 + 1))
  fi
  if (( WIN_HI < WIN_LO + 50 )); then WIN_HI=$((WIN_LO + 50)); fi
}

# judge <round> <key> <acked> <new-sha> [old-sha]: records the round. With
# old-sha the object must never be absent. Sets JUDGED_SHA to the sha now
# stored ("" when absent or wrong).
JUDGED_SHA=""
judge() {
  local round="$1" key="$2" acked="$3" new="$4" old="${5:-}" state verdict=ok
  state="$(object_state "$key" "$new" ${old:+"$old"})"
  JUDGED_SHA=""
  case "$state" in
    match:"$new")
      JUDGED_SHA="$new"
      if [[ "$acked" == yes ]]; then
        N_ACKED=$((N_ACKED + 1))
      else
        N_UNACKED_PRESENT=$((N_UNACKED_PRESENT + 1))
      fi ;;
    match:*)
      JUDGED_SHA="$old"
      if [[ "$acked" == yes ]]; then verdict=bad; else N_UNACKED_ABSENT=$((N_UNACKED_ABSENT + 1)); fi ;;
    absent)
      if [[ "$acked" == yes || -n "$old" ]]; then verdict=bad; else N_UNACKED_ABSENT=$((N_UNACKED_ABSENT + 1)); fi ;;
    *) verdict=bad ;;
  esac
  crash_rec "$round" "$KILL_DELAY" "$acked" "${state:0:200}" "$verdict"
}

crash_put() {
  local i t0 t1 key new
  head -c 4194304 /dev/urandom > "$TMP/c.bin"
  t0="$(now_ms)"
  if ! s3api put-object --bucket "$BUCKET" --key calib --body "$TMP/c.bin" >/dev/null; then
    CRASH_ABORT="calibration put: $AWS_ERR"; return 0
  fi
  t1="$(now_ms)"
  set_window $((t1 - t0))
  for i in $(seq 1 "$CRASH_ITER"); do
    key="k$i"
    head -c 4194304 /dev/urandom > "$TMP/c.bin"
    new="$(sha "$TMP/c.bin")"
    run_killed "$i" put-object --bucket "$BUCKET" --key "$key" --body "$TMP/c.bin"
    restart_after_kill "$i" || return 0
    judge "$i" "$key" "$KILL_ACKED" "$new"
    if [[ -n "$JUDGED_SHA" ]]; then ACKED["$key"]="$JUDGED_SHA"; fi
  done
}

crash_overwrite() {
  local i t0 t1 new cur
  head -c 4194304 /dev/urandom > "$TMP/c.bin"
  cur="$(sha "$TMP/c.bin")"
  t0="$(now_ms)"
  if ! s3api put-object --bucket "$BUCKET" --key ow --body "$TMP/c.bin" >/dev/null; then
    CRASH_ABORT="initial put: $AWS_ERR"; return 0
  fi
  t1="$(now_ms)"
  set_window $((t1 - t0))
  for i in $(seq 1 "$CRASH_ITER"); do
    head -c 4194304 /dev/urandom > "$TMP/c.bin"
    new="$(sha "$TMP/c.bin")"
    run_killed "$i" put-object --bucket "$BUCKET" --key ow --body "$TMP/c.bin"
    restart_after_kill "$i" || return 0
    judge "$i" ow "$KILL_ACKED" "$new" "$cur"
    if [[ -n "$JUDGED_SHA" ]]; then
      cur="$JUDGED_SHA"
    else
      # State unknown after a violation: write a known version to go on.
      if ! s3api put-object --bucket "$BUCKET" --key ow --body "$TMP/c.bin" >/dev/null; then
        CRASH_ABORT="round $i: recovery put: $AWS_ERR"; return 0
      fi
      cur="$new"
    fi
    ACKED[ow]="$cur"
  done
}

MP_UID=""
MP_SHA=""
# mp_prepare <key>: uploads two parts (5 MiB + 1 MiB) and writes cparts.json.
mp_prepare() {
  local key="$1" n etag parts="" sep=""
  MP_UID="$(s3api create-multipart-upload --bucket "$BUCKET" --key "$key" --query UploadId --output text)" || return 1
  head -c 5242880 /dev/urandom > "$TMP/cp1.bin"
  head -c 1048576 /dev/urandom > "$TMP/cp2.bin"
  for n in 1 2; do
    etag="$(s3api upload-part --bucket "$BUCKET" --key "$key" --upload-id "$MP_UID" \
      --part-number "$n" --body "$TMP/cp$n.bin" --query ETag --output json)" || return 1
    parts+="${sep}{\"ETag\":${etag},\"PartNumber\":${n}}"
    sep=","
  done
  printf '{"Parts":[%s]}' "$parts" > "$TMP/cparts.json"
  MP_SHA="$(cat "$TMP/cp1.bin" "$TMP/cp2.bin" | sha256sum | cut -d' ' -f1)"
}

crash_multipart() {
  local i t0 t1 key
  if ! mp_prepare calib; then CRASH_ABORT="calibration upload: $AWS_ERR"; return 0; fi
  t0="$(now_ms)"
  if ! s3api complete-multipart-upload --bucket "$BUCKET" --key calib --upload-id "$MP_UID" \
      --multipart-upload "file://$TMP/cparts.json" >/dev/null; then
    CRASH_ABORT="calibration complete: $AWS_ERR"; return 0
  fi
  t1="$(now_ms)"
  set_window $((t1 - t0))
  for i in $(seq 1 "$CRASH_ITER"); do
    key="m$i"
    if ! mp_prepare "$key"; then CRASH_ABORT="round $i: upload parts: $AWS_ERR"; return 0; fi
    run_killed "$i" complete-multipart-upload --bucket "$BUCKET" --key "$key" \
      --upload-id "$MP_UID" --multipart-upload "file://$TMP/cparts.json"
    restart_after_kill "$i" || return 0
    judge "$i" "$key" "$KILL_ACKED" "$MP_SHA"
    if [[ -n "$JUDGED_SHA" ]]; then
      ACKED["$key"]="$JUDGED_SHA"
    else
      s3api abort-multipart-upload --bucket "$BUCKET" --key "$key" --upload-id "$MP_UID" >/dev/null || true
    fi
  done
}

# Kills rustfs during start-up. The data dir already holds objects.
crash_start() {
  local i n t0 t1 hi delay state verdict key
  for n in 1 2 3; do
    head -c 1048576 /dev/urandom > "$TMP/c.bin"
    if ! s3api put-object --bucket "$BUCKET" --key "s$n" --body "$TMP/c.bin" >/dev/null; then
      CRASH_ABORT="seed put: $AWS_ERR"; return 0
    fi
    ACKED["s$n"]="$(sha "$TMP/c.bin")"
  done
  kill_rustfs
  t0="$(now_ms)"
  restart_after_kill calibration || return 0
  t1="$(now_ms)"
  hi=$(( (t1 - t0) * 11 / 10 ))
  log "start window: 0..${hi} ms"
  for i in $(seq 1 "$CRASH_ITER"); do
    kill_rustfs
    start_rustfs "crash round $i (killed during start)"
    delay="$(rand_ms 0 "$hi")"
    sleep_ms "$delay"
    kill_rustfs
    restart_after_kill "$i" || return 0
    key="s$(( i % 3 + 1 ))"
    verdict=ok
    state="$(object_state "$key" "${ACKED[$key]}")"
    if [[ "$state" == match:* ]]; then N_ACKED=$((N_ACKED + 1)); else verdict=bad; fi
    crash_rec "$i" "$delay" n/a "${state:0:200}" "$verdict"
  done
}

# Kills rustfs during its very first start on an empty data dir.
crash_fresh_start() {
  local i delay
  for i in $(seq 1 20); do
    start_rustfs "fresh start round $i (killed)"
    delay="$(rand_ms 0 4000)"
    sleep_ms "$delay"
    kill_rustfs
    printf 'fresh-%s\t%s\tn/a\tn/a\tok\n' "$i" "$delay" >> "$CRASH_TSV"
  done
}

step_crash() {
  local name="crash loop: $CRASH_OP" key state sweep_bad=0 rounds note n_yes n_no
  if [[ "${STATUS[2]}" != PASS ]]; then rec 3 "$name" SKIP "no bucket"; return 0; fi
  calibrate_cli
  if [[ "$CRASH_FAULT" == power ]]; then
    if [[ -z "$DM_MOUNT" || "$CRASH_OP" == start ]]; then
      echo "CRASH_FAULT=power needs fs=local or a cifs flavour and an object operation" >&2
      exit 2
    fi
    # The format written at first start must not be part of what gets lost.
    sudo sync -f "$DM_MOUNT"
  fi
  case "$CRASH_OP" in
    put)       crash_put ;;
    overwrite) crash_overwrite ;;
    multipart) crash_multipart ;;
    start)     crash_start ;;
    *) echo "unknown CRASH_OP: $CRASH_OP" >&2; exit 2 ;;
  esac
  rounds="$(grep -c -v '^fresh-' "$CRASH_TSV" || true)"
  note="rounds=$rounds acked=$N_ACKED unacked_absent_or_old=$N_UNACKED_ABSENT unacked_complete=$N_UNACKED_PRESENT violations=$N_BAD"
  if [[ -n "$CRASH_ABORT" ]]; then
    rec 3 "$name" FAIL "$CRASH_ABORT; $note"
    rec 4 "final sweep of acknowledged objects" SKIP "loop aborted"
    return 0
  fi
  # A loop in which the kill never came before or never came after the
  # acknowledgement has not tested the commit and must not count as passed.
  n_yes="$(awk -F'	' '$3 == "yes"' "$CRASH_TSV" | wc -l)"
  n_no="$(awk -F'	' '$3 == "no"' "$CRASH_TSV" | wc -l)"
  if (( N_BAD > 0 )); then
    rec 3 "$name" FAIL "$note"
  elif [[ "$CRASH_OP" != start ]] && (( n_yes == 0 || n_no == 0 )); then
    rec 3 "$name" FAIL "kill window missed: acknowledged=$n_yes unacknowledged=$n_no; $note"
  else
    rec 3 "$name" PASS "$note"
  fi

  for key in "${!ACKED[@]}"; do
    state="$(object_state "$key" "${ACKED[$key]}")"
    if [[ "$state" != match:* ]]; then
      sweep_bad=$((sweep_bad + 1))
      log "final sweep: $key $state"
    fi
  done
  if (( sweep_bad > 0 )); then
    rec 4 "final sweep of acknowledged objects" FAIL "$sweep_bad of ${#ACKED[@]} objects wrong"
  else
    rec 4 "final sweep of acknowledged objects" PASS "${#ACKED[@]} objects"
  fi
}

# ------------------------------------------------------------------ main ----
log "binary: $BIN"
"$BIN" --version 2>&1 | head -3 > "$OUT_DIR/version.txt" || true

prepare_fs
inode_probe

if [[ "${CELL_MODE:-steps}" == crash ]]; then
  : > "$CRASH_TSV"
  if [[ "$CRASH_OP" == start ]]; then crash_fresh_start; fi
  step_start
  step_bucket
  step_crash
else
  step_start
  step_bucket
  step_simple
  step_multipart
  step_delete
  step_restart
fi

stop_rustfs
if [[ "$IS_CIFS" == 1 ]]; then
  sudo dmesg 2>/dev/null | grep -i cifs | tail -100 > "$OUT_DIR/dmesg-cifs.txt" || true
  docker logs "$CONTAINER" > "$OUT_DIR/samba.log" 2>&1 || true
fi

python3 -I "$SCRIPT_DIR/render-result.py" "$OUT_DIR" "$TARGET" "$FS"

if grep -q -P '\tFAIL\t' "$OUT_DIR/steps.tsv"; then
  exit 1
fi
exit 0
