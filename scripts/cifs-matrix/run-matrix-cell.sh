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
#
# Optional environment:
#   RUSTFS_EXTRA_ENV   whitespace separated KEY=VALUE pairs passed to rustfs
#   CELL_WORK_DIR      scratch directory (default /mnt/cifs-matrix)

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
WORK="${CELL_WORK_DIR:-/mnt/cifs-matrix}"
EXTRA_ENV="${RUSTFS_EXTRA_ENV:-}"

PORT=9000
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
CACHE_OPT=""
SERVERINO_OPT=""

case "$FS" in
  local) ;;
  cifs-noserverino)        IS_CIFS=1; CACHE_OPT="cache=none";   SERVERINO_OPT="noserverino" ;;
  cifs-serverino)          IS_CIFS=1; CACHE_OPT="cache=none";   SERVERINO_OPT="serverino" ;;
  cifs-noserverino-strict) IS_CIFS=1; CACHE_OPT="cache=strict"; SERVERINO_OPT="noserverino" ;;
  *) echo "unknown fs: $FS" >&2; exit 2 ;;
esac

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
  return 0
}
trap cleanup EXIT
trap 'exit 143' TERM INT

# ------------------------------------------------------------ filesystem ----
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
  sudo mount -t cifs //127.0.0.1/data "$MNT" -o "$opts"
}

prepare_fs() {
  sudo mkdir -p "$WORK"
  sudo chown "$(id -u):$(id -g)" "$WORK"
  rm -rf "$EXPORT" "$MNT" "$TMP" "$WORK/local-data"
  mkdir -p "$EXPORT" "$MNT" "$TMP"

  if [[ "$IS_CIFS" == 1 ]]; then
    setup_cifs
    DATA="$MNT/data"
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
  timeout 180 aws --no-cli-pager --endpoint-url "$ENDPOINT" \
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

# ------------------------------------------------------------------ main ----
log "binary: $BIN"
"$BIN" --version 2>&1 | head -3 > "$OUT_DIR/version.txt" || true

prepare_fs
inode_probe

step_start
step_bucket
step_simple
step_multipart
step_delete
step_restart

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
