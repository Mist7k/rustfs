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

"""Render result.json / result.md for one CIFS matrix cell.

Usage: render-result.py <out-dir> <target> <fs>
Reads steps.tsv, rustfs.log, inode.txt, mounts.txt, version.txt from out-dir.
"""

import json
import os
import sys

SIGNATURES = [
    "FileCorrupt",
    "transaction_unknown",
    "rename_indeterminate",
    "erasure write quorum",
    "Invalid argument",
    "stage=read_file_all",
]


def read_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def main():
    out, target, fs = sys.argv[1:4]

    steps = []
    for line in read_text(os.path.join(out, "steps.tsv")).splitlines():
        parts = line.split("\t")
        if len(parts) >= 3:
            steps.append(
                {"id": int(parts[0]), "name": parts[1], "status": parts[2],
                 "note": parts[3] if len(parts) > 3 else ""}
            )

    log_lines = read_text(os.path.join(out, "rustfs.log")).splitlines()
    signatures = []
    for sig in SIGNATURES:
        hits = [l for l in log_lines if sig in l]
        signatures.append({"signature": sig, "count": len(hits),
                           "first": [h[:400] for h in hits[:3]]})

    inode = read_text(os.path.join(out, "inode.txt")).strip()
    inode_equal = "unknown"
    for line in inode.splitlines():
        if line.startswith("inodes_equal:"):
            inode_equal = line.split(":", 1)[1].strip()

    mounts = read_text(os.path.join(out, "mounts.txt")).strip()
    version = read_text(os.path.join(out, "version.txt")).strip()
    failed = [s for s in steps if s["status"] == "FAIL"]

    result = {
        "target": target,
        "fs": fs,
        "overall": "FAIL" if failed else "PASS",
        "version": version,
        "steps": steps,
        "signatures": signatures,
        "inode_probe": {"inodes_equal": inode_equal, "raw": inode},
        "mount": mounts,
    }
    with open(os.path.join(out, "result.json"), "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2)

    def cell(text):
        return str(text).replace("|", "\\|").replace("\n", " ")

    md = ["### %s on %s: %s" % (target, fs, result["overall"]), ""]
    if version:
        md += ["Binary version: `%s`" % cell(version.splitlines()[0]), ""]
    md += ["| # | Step | Status | Note |", "|---|---|---|---|"]
    for s in steps:
        md.append("| %d | %s | %s | %s |" % (s["id"], cell(s["name"]), s["status"], cell(s["note"])))
    md += ["", "| Log signature | Count | First match |", "|---|---|---|"]
    for s in signatures:
        first = s["first"][0] if s["first"] else ""
        md.append("| `%s` | %d | %s |" % (s["signature"], s["count"], cell(first)))
    md += ["", "Inode probe (hardlink a/b): inodes equal = **%s**" % inode_equal, "",
           "```", inode, "```", "", "Mount / filesystem:", "", "```", mounts, "```", ""]
    text = "\n".join(md)

    with open(os.path.join(out, "result.md"), "w", encoding="utf-8") as f:
        f.write(text)

    print(text)
    for s in signatures:
        print("signature %r: %d" % (s["signature"], s["count"]))
        for h in s["first"]:
            print("    " + h)

    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write(text + "\n")


if __name__ == "__main__":
    main()
