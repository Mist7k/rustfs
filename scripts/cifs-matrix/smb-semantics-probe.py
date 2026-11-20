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

"""Probe the file-system semantics RustFS commit paths rely on, on a real mount.

Usage: smb-semantics-probe.py <mount-root>

The only thing created or removed under <mount-root> is one fresh directory
".cifscompat-<UTC timestamp>". Every case prints one line "CASE <name>: <result>".
"""

import errno
import os
import re
import shutil
import signal
import sys
import time


def result(name, fn):
    try:
        value = fn()
        print("CASE %s: ok%s" % (name, "" if value is None else " " + str(value)), flush=True)
    except OSError as error:
        print("CASE %s: FAILED errno=%s (%s)" % (name, errno.errorcode.get(error.errno, error.errno), error.strerror),
              flush=True)


def write(path, data=b"x"):
    with open(path, "wb") as handle:
        handle.write(data)


def main():
    root = sys.argv[1].rstrip("/")
    fstype, best = "", -1
    with open("/proc/mounts", encoding="utf-8") as mounts:
        for line in mounts:
            fields = line.split()
            point = fields[1]
            if (root == point or root.startswith(point.rstrip("/") + "/")) and len(point) > best:
                best, fstype = len(point), fields[2]
    if fstype not in ("cifs", "smb3") and os.environ.get("PROBE_ALLOW_ANY_FS") != "1":
        sys.exit("ABORT: %s is on %r, not a cifs/smb3 mount" % (root, fstype))
    print("root=%s fstype=%s" % (root, fstype), flush=True)
    test_dir = "%s/.cifscompat-%s" % (root, time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()))
    os.mkdir(test_dir)

    def cleanup(*_):
        if re.fullmatch(re.escape(root) + r"/\.cifscompat-[0-9]{8}T[0-9]{6}Z", test_dir):
            for _attempt in range(5):
                shutil.rmtree(test_dir, ignore_errors=True)
                if not os.path.lexists(test_dir):
                    break
                time.sleep(2)
        print("CLEANUP test_dir_removed=%s path=%s" % ("no" if os.path.lexists(test_dir) else "yes", test_dir))
        left = [name for name in os.listdir(root) if name.startswith(".cifscompat-")]
        print("CLEANUP remaining_cifscompat_dirs=%d %s" % (len(left), " ".join(left)), flush=True)

    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        run(test_dir)
    finally:
        cleanup()
        print("PROBE DONE", flush=True)


def run(base):
    counter = [0]

    def fresh():
        counter[0] += 1
        path = os.path.join(base, "case%d" % counter[0])
        os.mkdir(path)
        return path

    def rename_over(target_flags):
        directory = fresh()
        target, source = os.path.join(directory, "target"), os.path.join(directory, "source")
        write(target, b"old")
        write(source, b"new")
        handle = os.open(target, target_flags) if target_flags is not None else None
        try:
            os.rename(source, target)
        finally:
            if handle is not None:
                os.close(handle)

    result("rename_over_closed_target", lambda: rename_over(None))
    result("rename_over_target_open_rdonly", lambda: rename_over(os.O_RDONLY))
    result("rename_over_target_open_rdwr", lambda: rename_over(os.O_RDWR))

    def rename_open_source(flags):
        directory = fresh()
        source = os.path.join(directory, "source")
        write(source)
        handle = os.open(source, flags)
        try:
            os.rename(source, os.path.join(directory, "renamed"))
        finally:
            os.close(handle)

    result("rename_source_open_rdonly", lambda: rename_open_source(os.O_RDONLY))
    result("rename_source_open_rdwr", lambda: rename_open_source(os.O_RDWR))

    def unlink_open(flags):
        directory = fresh()
        path = os.path.join(directory, "file")
        write(path)
        handle = os.open(path, flags)
        try:
            os.unlink(path)
        finally:
            os.close(handle)

    result("unlink_open_rdonly", lambda: unlink_open(os.O_RDONLY))
    result("unlink_open_rdwr", lambda: unlink_open(os.O_RDWR))

    def rename_directory(open_what):
        directory = fresh()
        inner = os.path.join(directory, "inner")
        os.mkdir(inner)
        write(os.path.join(inner, "file"))
        handle = None
        if open_what == "file":
            handle = os.open(os.path.join(inner, "file"), os.O_RDONLY)
        elif open_what == "dir":
            handle = os.open(inner, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.rename(inner, os.path.join(directory, "moved"))
        finally:
            if handle is not None:
                os.close(handle)

    result("rename_directory_nothing_open", lambda: rename_directory(None))
    result("rename_directory_with_open_file", lambda: rename_directory("file"))
    result("rename_directory_with_open_dirfd", lambda: rename_directory("dir"))

    def hardlink():
        directory = fresh()
        first, second = os.path.join(directory, "a"), os.path.join(directory, "b")
        write(first)
        handle = os.open(first, os.O_RDONLY)
        try:
            os.link(first, second)
            pinned, a, b = os.fstat(handle), os.stat(first), os.stat(second)
            return "fd_ino==a_ino:%s a_ino==b_ino:%s nlink=%d dev_equal:%s" % (
                pinned.st_ino == a.st_ino, a.st_ino == b.st_ino, b.st_nlink, a.st_dev == b.st_dev)
        finally:
            os.close(handle)

    result("hardlink_with_open_source", hardlink)

    def reopen_identity():
        directory = fresh()
        path = os.path.join(directory, "file")
        write(path)
        handle = os.open(path, os.O_RDONLY)
        try:
            before = os.fstat(handle)
            again = os.stat(path)
            os.rename(path, os.path.join(directory, "renamed"))
            after = os.stat(os.path.join(directory, "renamed"))
            return "fd_ino==path_ino:%s fd_ino==renamed_path_ino:%s" % (
                before.st_ino == again.st_ino, before.st_ino == after.st_ino)
        finally:
            os.close(handle)

    result("inode_stability_across_rename", reopen_identity)

    def exclusive_copy():
        directory = fresh()
        dir_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            handle = os.open("copy", os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_NOFOLLOW, 0o666, dir_fd=dir_fd)
            try:
                os.write(handle, b"payload")
                data = os.pread(handle, 16, 0)
                os.fdatasync(handle)
                return "readback_ok:%s" % (data == b"payload")
            finally:
                os.close(handle)
        finally:
            os.close(dir_fd)

    result("exclusive_rdwr_copy_readback_fdatasync", exclusive_copy)

    def sync_readonly():
        directory = fresh()
        path = os.path.join(directory, "file")
        write(path)
        handle = os.open(path, os.O_RDONLY)
        try:
            os.fdatasync(handle)
        finally:
            os.close(handle)

    result("fdatasync_on_rdonly_fd", sync_readonly)

    def sync_directory():
        directory = fresh()
        handle = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(handle)
        finally:
            os.close(handle)

    result("fsync_directory_fd", sync_directory)

    def pool_meta_like():
        # Mirrors the pool metadata update: the predecessor stays pinned through
        # a read-only fd, a backup copy stays open read-write, a staged file is
        # renamed over the predecessor.
        directory = fresh()
        head, backup, staged = (os.path.join(directory, name) for name in ("head", "backup", "staged"))
        write(head, b"old")
        pinned = os.open(head, os.O_RDONLY)
        copy = os.open(backup, os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o666)
        try:
            os.write(copy, b"old")
            os.fdatasync(copy)
            write(staged, b"new")
            os.rename(staged, head)
        finally:
            os.close(copy)
            os.close(pinned)

    result("rename_over_pinned_head_with_open_backup", pool_meta_like)


if __name__ == "__main__":
    main()
