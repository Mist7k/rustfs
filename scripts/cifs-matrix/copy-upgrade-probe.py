#!/usr/bin/env python3
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

"""Upgrade test on a copy of an existing RustFS data dir.

Copies the system dir and a bounded set of buckets from a read-only source
into a fresh test dir, then runs: old binary -> new binary -> new binary
writes and restarts -> old binary again. After every start all objects are
listed and read; the result must equal what the old binary returned first.

The source is only read. Everything written lives in
$SB_ROOT/.cifscompat-<timestamp> and is removed on exit.

Environment:
  SRC                read-only source data dir (contains .rustfs.sys)
  SB_ROOT            mount that receives the test dir
  BUCKETS            space separated bucket names to copy
  OLD_URL, NEW_URL   zip downloads holding one "rustfs" binary each
  NEW_ENV            extra env for the new binary, space separated K=V
  BUCKET_MAX_BYTES   per bucket copy limit (default 5 GiB)
  BUCKET_MAX_SECONDS per bucket copy limit (default 1500)
  SYS_MAX_BYTES      limit for .rustfs.sys (default 12 GiB)
  MIN_FREE_BYTES     abort when less would stay free (default 300 GiB)
"""

import atexit
import collections
import concurrent.futures as cf
import copy
import hashlib
import json
import os
import re
import secrets
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import zipfile

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

GIB = 1 << 30
SRC = os.environ["SRC"]
SB_ROOT = os.environ["SB_ROOT"]
BUCKETS = os.environ.get("BUCKETS", "").split()
BUCKET_MAX_BYTES = int(os.environ.get("BUCKET_MAX_BYTES", 5 * GIB))
BUCKET_MAX_SECONDS = int(os.environ.get("BUCKET_MAX_SECONDS", 1500))
SYS_MAX_BYTES = int(os.environ.get("SYS_MAX_BYTES", 12 * GIB))
MIN_FREE_BYTES = int(os.environ.get("MIN_FREE_BYTES", 300 * GIB))
NEW_ENV = dict(kv.split("=", 1) for kv in os.environ.get("NEW_ENV", "").split())
PORT = 9000
ENDPOINT = f"http://127.0.0.1:{PORT}"
ACCESS_KEY = "cifscompat" + secrets.token_hex(4)
SECRET_KEY = secrets.token_hex(16)
LOG = "/tmp/rustfs.log"
MARK = "zz-cifscompat"

T = os.path.join(SB_ROOT, ".cifscompat-" + time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()))
DATA = os.path.join(T, "data")
proc = None
results = []


def say(msg):
    print(f"[{time.strftime('%H:%M:%S', time.gmtime())}] {msg}", flush=True)


def rec(step, status, note=""):
    results.append((step, status, note))
    say(f"STEP {step}: {status} {note}")


def free_bytes():
    st = os.statvfs(SB_ROOT)
    return st.f_bavail * st.f_frsize


def stop_rustfs():
    global proc
    if proc is None:
        return
    proc.terminate()
    try:
        proc.wait(30)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    proc = None


def cleanup():
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    stop_rustfs()
    if T.startswith(os.path.join(SB_ROOT, ".cifscompat-")) and os.path.isdir(T):
        shutil.rmtree(T, ignore_errors=True)
        if os.path.isdir(T):
            shutil.rmtree(T, ignore_errors=True)
    left = [n for n in os.listdir(SB_ROOT) if n.startswith(".cifscompat-")]
    print(f"test_dir_removed={'no' if os.path.exists(T) else 'yes'} path={T}", flush=True)
    print(f"remaining_cifscompat_dirs={len(left)}", flush=True)
    print(f"free_gib_after={free_bytes() / GIB:.1f}", flush=True)


def on_term(signum, frame):
    sys.exit(143)


# ------------------------------------------------------------------ copy ----
class Budget(Exception):
    pass


LOCK = threading.Lock()


def copy_file(src, dst, state):
    """state: shared {"bytes", "max", "stop"}; every chunk is counted and checked."""
    n = 0
    with open(src, "rb") as fi, open(dst, "wb") as fo:
        while True:
            if state["stop"]:
                raise Budget(state["stop"])
            buf = fi.read(4 << 20)
            if not buf:
                return n
            fo.write(buf)
            n += len(buf)
            with LOCK:
                state["bytes"] += len(buf)
                over = state["bytes"] > state["max"]
            if over:
                state["stop"] = f"more than {state['max'] / GIB:.1f} GiB"
            elif free_bytes() < MIN_FREE_BYTES:
                state["stop"] = "free space limit reached"


def copy_tree(src, dst, max_bytes, max_secs, skip=()):
    """Returns (files, bytes, vanished). Raises Budget when a limit is hit."""
    if not os.path.isdir(src):
        raise Budget("source dir missing")
    start = time.time()
    files = total = vanished = 0
    pending = set()
    state = {"bytes": 0, "max": max_bytes, "stop": ""}

    def drain(block_all):
        nonlocal files, total, vanished
        done, rest = cf.wait(pending, return_when=cf.ALL_COMPLETED if block_all else cf.FIRST_COMPLETED)
        pending.clear()
        pending.update(rest)
        for f in done:
            try:
                total += f.result()
                files += 1
            except FileNotFoundError:
                vanished += 1

    with cf.ThreadPoolExecutor(4) as pool:
        try:
            stack = [(src, dst)]
            os.makedirs(dst, exist_ok=True)
            while stack:
                s, d = stack.pop()
                try:
                    entries = list(os.scandir(s))
                except FileNotFoundError:
                    vanished += 1
                    continue
                for e in entries:
                    if s == src and e.name in skip:
                        continue
                    target = os.path.join(d, e.name)
                    if e.is_symlink():
                        continue
                    if e.is_dir(follow_symlinks=False):
                        os.makedirs(target, exist_ok=True)
                        stack.append((e.path, target))
                    else:
                        pending.add(pool.submit(copy_file, e.path, target, state))
                        if len(pending) >= 32:
                            drain(False)
                    if state["stop"]:
                        raise Budget(state["stop"])
                    if time.time() - start > max_secs:
                        raise Budget(f"more than {max_secs}s")
            drain(True)
        except BaseException as e:
            state["stop"] = state["stop"] or f"aborted: {type(e).__name__}"
            raise
        finally:
            for f in pending:
                f.cancel()
    return files, total, vanished


def step_copy():
    say(f"free before: {free_bytes() / GIB:.1f} GiB, test dir {T}")
    if free_bytes() < MIN_FREE_BYTES + SYS_MAX_BYTES:
        rec("1 copy", "FAIL", "not enough free space to start")
        return False
    os.makedirs(DATA)
    try:
        f, b, v = copy_tree(os.path.join(SRC, ".rustfs.sys"), os.path.join(DATA, ".rustfs.sys"), SYS_MAX_BYTES, 3600, skip=("tmp",))
    except (Budget, OSError) as e:
        rec("1 copy", "FAIL", f".rustfs.sys: {e}")
        return False
    os.makedirs(os.path.join(DATA, ".rustfs.sys", "tmp"), exist_ok=True)
    say(f"copied .rustfs.sys: {f} files, {b / GIB:.2f} GiB, vanished {v}")
    copied = []
    for bucket in BUCKETS:
        dst = os.path.join(DATA, bucket)
        try:
            f, b, v = copy_tree(os.path.join(SRC, bucket), dst, BUCKET_MAX_BYTES, BUCKET_MAX_SECONDS)
            say(f"copied bucket {bucket}: {f} files, {b / GIB:.2f} GiB, vanished {v}")
            copied.append(bucket)
        except (Budget, OSError) as e:
            say(f"bucket {bucket} left out: {e}")
            shutil.rmtree(dst, ignore_errors=True)
    rec("1 copy", "PASS" if copied else "FAIL", f"buckets: {' '.join(copied)}; free now {free_bytes() / GIB:.1f} GiB")
    return bool(copied)


# ---------------------------------------------------------------- rustfs ----
def fetch(url, dest):
    os.makedirs(dest, exist_ok=True)
    z = os.path.join(dest, "b.zip")
    urllib.request.urlretrieve(url, z)
    zipfile.ZipFile(z).extract("rustfs", dest)
    path = os.path.join(dest, "rustfs")
    os.chmod(path, 0o755)
    return path


log_pos = 0


def start_rustfs(binary, extra, label):
    global proc, log_pos
    stop_rustfs()
    log_pos = os.path.getsize(LOG) if os.path.exists(LOG) else 0
    env = dict(
        PATH=os.environ.get("PATH", ""),
        RUSTFS_VOLUMES=DATA,
        RUSTFS_ADDRESS=f"127.0.0.1:{PORT}",
        RUSTFS_ACCESS_KEY=ACCESS_KEY,
        RUSTFS_SECRET_KEY=SECRET_KEY,
        RUSTFS_CONSOLE_ENABLE="false",
        RUSTFS_UNSUPPORTED_FS_POLICY="warn",
        RUSTFS_OBS_LOGGER_LEVEL="info",
        RUSTFS_OBS_LOG_STDOUT_ENABLED="true",
    )
    env.update(extra)
    with open(LOG, "ab") as lf:
        lf.write(f"=== starting rustfs ({label}) ===\n".encode())
        proc = subprocess.Popen([binary], env=env, stdout=lf, stderr=subprocess.STDOUT)
    deadline = time.time() + 600
    code = None
    while time.time() < deadline:
        if proc.poll() is not None:
            return f"process exited with {proc.returncode} before becoming ready"
        for path in ("/health/ready", "/health"):
            try:
                with urllib.request.urlopen(ENDPOINT + path, timeout=3) as r:
                    code = r.status
            except urllib.error.HTTPError as e:
                code = e.code
            except OSError:
                code = None
            if code != 404:
                break
        if code == 200:
            return ""
        time.sleep(1)
    return f"not ready after 600s (last http={code})"


ANSI = re.compile(r"\x1b\[[0-9;]*m")
NOISE = re.compile(r"[0-9a-f]{8}-[0-9a-f-]{27}|\d{4}-\d\d-\d\dT[\d:.]+Z?|\d+")


def log_report(label):
    """Counts and samples the error lines written since the last start."""
    with open(LOG, "rb") as f:
        f.seek(log_pos)
        lines = f.read().decode("utf-8", "replace").splitlines()
    errs = collections.Counter()
    for line in lines:
        line = ANSI.sub("", line)
        if "ERROR" in line or "panic" in line:
            errs[NOISE.sub("#", line)[:260]] += 1
    say(f"log {label}: {len(lines)} lines, {sum(errs.values())} error lines, {len(errs)} distinct")
    for msg, n in errs.most_common(6):
        say(f"  {n}x {msg}")


def log_tail(n=25):
    with open(LOG, "rb") as f:
        f.seek(max(0, os.path.getsize(LOG) - 12000))
        for line in f.read().decode("utf-8", "replace").splitlines()[-n:]:
            say("  | " + ANSI.sub("", line)[:300])


# -------------------------------------------------------------------- s3 ----
def client():
    return boto3.client(
        "s3",
        endpoint_url=ENDPOINT,
        region_name="us-east-1",
        aws_access_key_id=ACCESS_KEY,
        aws_secret_access_key=SECRET_KEY,
        config=Config(s3={"addressing_style": "path"}, retries={"max_attempts": 2}, read_timeout=120, max_pool_connections=8),
    )


def err_code(e):
    if isinstance(e, ClientError):
        return "ERR:" + str(e.response.get("Error", {}).get("Code"))
    return "ERR:" + type(e).__name__


def get_sha(s3, bucket, key):
    try:
        body = s3.get_object(Bucket=bucket, Key=key)["Body"]
        h = hashlib.sha256()
        for chunk in iter(lambda: body.read(1 << 20), b""):
            h.update(chunk)
        return h.hexdigest()
    except (ClientError, BotoCoreError, OSError) as e:
        return err_code(e)


def manifest(s3):
    out = {}
    names = sorted(b["Name"] for b in s3.list_buckets().get("Buckets", []))
    with cf.ThreadPoolExecutor(4) as pool:
        for b in names:
            meta = {}
            for name, fn in (
                ("versioning", s3.get_bucket_versioning),
                ("policy", s3.get_bucket_policy),
                ("lifecycle", s3.get_bucket_lifecycle_configuration),
            ):
                try:
                    r = fn(Bucket=b)
                    r.pop("ResponseMetadata", None)
                    meta[name] = json.dumps(r, sort_keys=True, default=str)
                except (ClientError, BotoCoreError) as e:
                    meta[name] = err_code(e)
            sizes = {}
            try:
                for page in s3.get_paginator("list_objects_v2").paginate(Bucket=b):
                    for o in page.get("Contents", []):
                        sizes[o["Key"]] = o["Size"]
            except (ClientError, BotoCoreError) as e:
                meta["list"] = err_code(e)
            try:
                n = 0
                for page in s3.get_paginator("list_object_versions").paginate(Bucket=b):
                    n += len(page.get("Versions", [])) + len(page.get("DeleteMarkers", []))
                meta["versions"] = n
            except (ClientError, BotoCoreError) as e:
                meta["versions"] = err_code(e)
            keys = sorted(sizes)
            shas = pool.map(lambda k: get_sha(s3, b, k), keys)
            out[b] = {"meta": meta, "objects": {k: [sizes[k], s] for k, s in zip(keys, shas)}}
    return out


def describe(m):
    objs = sum(len(b["objects"]) for b in m.values())
    bad = sum(1 for b in m.values() for o in b["objects"].values() if o[1].startswith("ERR:"))
    size = sum(o[0] for b in m.values() for o in b["objects"].values())
    return f"{len(m)} buckets, {objs} objects, {size / GIB:.2f} GiB, {bad} unreadable"


def diff(want, got):
    d = []
    for b in sorted(set(want) | set(got)):
        if b not in got:
            d.append(f"bucket {b} missing")
            continue
        if b not in want:
            d.append(f"bucket {b} unexpected")
            continue
        for k in sorted(set(want[b]["meta"]) | set(got[b]["meta"])):
            if want[b]["meta"].get(k) != got[b]["meta"].get(k):
                d.append(f"{b} {k}: {str(want[b]['meta'].get(k))[:80]} -> {str(got[b]['meta'].get(k))[:80]}")
        wo, go = want[b]["objects"], got[b]["objects"]
        for k in sorted(set(wo) | set(go)):
            if k not in go:
                d.append(f"{b}/{k} missing")
            elif k not in wo:
                d.append(f"{b}/{k} unexpected")
            elif wo[k] != go[k]:
                d.append(f"{b}/{k}: {wo[k][0]} {wo[k][1][:12]} -> {go[k][0]} {go[k][1][:12]}")
    return d


def check(step, want, got):
    d = diff(want, got)
    if d:
        for line in d[:15]:
            say("  diff: " + line)
        rec(step, "FAIL", f"{len(d)} differences; got {describe(got)}")
    else:
        rec(step, "PASS", describe(got))
    return not d


def put(s3, exp, bucket, key, data):
    s3.put_object(Bucket=bucket, Key=key, Body=data)
    exp.setdefault(bucket, {"meta": {}, "objects": {}})["objects"][key] = [len(data), hashlib.sha256(data).hexdigest()]


def writes(s3, exp):
    """New bucket, PUT, multipart, and in one copied bucket: add, overwrite, delete."""
    nb = MARK + "-new"
    s3.create_bucket(Bucket=nb)
    put(s3, exp, nb, "small", os.urandom(1 << 20))
    p1, p2 = os.urandom(5 << 20), os.urandom(1 << 20)
    uid = s3.create_multipart_upload(Bucket=nb, Key="mp")["UploadId"]
    parts = []
    for i, p in enumerate((p1, p2), 1):
        etag = s3.upload_part(Bucket=nb, Key="mp", UploadId=uid, PartNumber=i, Body=p)["ETag"]
        parts.append({"PartNumber": i, "ETag": etag})
    s3.complete_multipart_upload(Bucket=nb, Key="mp", UploadId=uid, MultipartUpload={"Parts": parts})
    exp[nb]["objects"]["mp"] = [len(p1) + len(p2), hashlib.sha256(p1 + p2).hexdigest()]
    note = [f"bucket {nb}: put, multipart"]
    for b in sorted(exp):
        good = [k for k, o in exp[b]["objects"].items() if not o[1].startswith("ERR:")]
        if b == nb or len(good) < 2 or exp[b]["meta"].get("versioning") != "{}":
            continue
        put(s3, exp, b, MARK + "/post", os.urandom(1 << 20))
        put(s3, exp, b, good[0], os.urandom(300000))
        s3.delete_object(Bucket=b, Key=good[1])
        del exp[b]["objects"][good[1]]
        note.append(f"bucket {b}: add, overwrite, delete")
        break
    return "; ".join(note)


def refresh_meta(exp, got):
    """Bucket settings of buckets created by the test are taken as observed."""
    for b in exp:
        if b.startswith(MARK) and b in got:
            exp[b]["meta"] = copy.deepcopy(got[b]["meta"])
    for b in exp:
        if b in got and "versions" in got[b]["meta"] and b in WROTE:
            exp[b]["meta"]["versions"] = got[b]["meta"]["versions"]


WROTE = set()


def main():
    signal.signal(signal.SIGTERM, on_term)
    atexit.register(cleanup)
    old_bin = fetch(os.environ["OLD_URL"], "/tmp/rustfs-old")
    new_bin = fetch(os.environ["NEW_URL"], "/tmp/rustfs-new")
    if not step_copy():
        return

    note = start_rustfs(old_bin, {}, "old")
    if note:
        log_tail()
        rec("2 old binary start", "FAIL", note)
        return
    rec("2 old binary start", "PASS")
    s3 = client()
    base = manifest(s3)
    log_report("old binary")
    bad = sum(1 for b in base.values() for o in b["objects"].values() if o[1].startswith("ERR:"))
    rec("3 old binary reads the copy", "PASS" if base and not bad else "INFO", describe(base))
    for b, v in base.items():
        say(f"  {b}: {len(v['objects'])} objects, meta {json.dumps(v['meta'])[:200]}")
    if not any(v["objects"] for v in base.values()):
        rec("3 old binary reads the copy", "FAIL", "no objects, nothing to compare")
        return

    note = start_rustfs(new_bin, NEW_ENV, "new")
    if note:
        log_tail()
        rec("4 new binary start", "FAIL", note)
        return
    rec("4 new binary start", "PASS")
    got = manifest(s3)
    log_report("new binary")
    check("5 new binary reads the same", base, got)

    exp = copy.deepcopy(got)
    try:
        before = {b: dict(v["objects"]) for b, v in exp.items()}
        wnote = writes(s3, exp)
        WROTE.update(b for b in exp if exp[b]["objects"] != before.get(b))
        rec("6 new binary writes", "PASS", wnote)
    except (ClientError, BotoCoreError) as e:
        log_tail()
        rec("6 new binary writes", "FAIL", str(e)[:200])
        return

    note = start_rustfs(new_bin, NEW_ENV, "new restart")
    if note:
        log_tail()
        rec("7 new binary restart", "FAIL", note)
        return
    got = manifest(s3)
    refresh_meta(exp, got)
    log_report("new binary restart")
    check("7 new binary restart, all objects", exp, got)

    note = start_rustfs(old_bin, {}, "old again")
    if note:
        log_tail()
        rec("8 old binary takes the dir back", "FAIL", note)
        return
    rec("8 old binary takes the dir back", "PASS")
    got = manifest(s3)
    log_report("old binary again")
    check("9 old binary reads everything", exp, got)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001 - every crash must show up in the summary
        rec("aborted", "FAIL", f"{type(e).__name__}: {str(e)[:300]}")
    finally:
        print("=== summary ===", flush=True)
        for step, status, note in results:
            print(f"{status:5} {step}  {note}", flush=True)
