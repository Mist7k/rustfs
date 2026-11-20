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

"""Combine all per-cell result.json files into one target x fs table.

Usage: combine-results.py <dir-with-downloaded-artifacts>
Prints markdown to stdout and appends it to $GITHUB_STEP_SUMMARY when set.
"""

import glob
import json
import os
import sys

SHORT = {"PASS": "P", "FAIL": "F", "SKIP": "-"}


def main():
    root = sys.argv[1]
    results = []
    for path in sorted(glob.glob(os.path.join(root, "**", "result.json"), recursive=True)):
        with open(path, encoding="utf-8") as f:
            results.append(json.load(f))

    lines = ["## CIFS matrix", ""]
    if not results:
        lines.append("No result artifacts were found.")
    else:
        step_names = {}
        for r in results:
            for s in r["steps"]:
                step_names[s["id"]] = s["name"]
        ids = sorted(step_names)
        lines.append("Steps: " + ", ".join("s%d = %s" % (i, step_names[i]) for i in ids)
                     + ". P = PASS, F = FAIL, - = SKIP.")
        lines.append("")
        header = ["target", "fs", "overall"] + ["s%d" % i for i in ids] + ["inodes equal", "signature hits"]
        lines.append("| " + " | ".join(header) + " |")
        lines.append("|" + "---|" * len(header))
        for r in sorted(results, key=lambda r: (r["target"], r["fs"])):
            by_id = {s["id"]: s["status"] for s in r["steps"]}
            cells = [SHORT.get(by_id.get(i, "SKIP"), "?") for i in ids]
            hits = ", ".join("%s=%d" % (s["signature"], s["count"]) for s in r["signatures"] if s["count"])
            lines.append("| " + " | ".join(
                [r["target"], r["fs"], r["overall"]] + cells
                + [r["inode_probe"]["inodes_equal"], hits or "none"]) + " |")

    text = "\n".join(lines) + "\n"
    print(text)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write(text)


if __name__ == "__main__":
    main()
