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

# Fetches the two binaries for the CIFS Baseline workflow:
#   $RUNNER_TEMP/rustfs-old/rustfs  upstream release $BASELINE_TAG
#   $RUNNER_TEMP/rustfs-bin/rustfs  branch binary from the newest CIFS Matrix
#                                   run that still has its build artifact

set -euo pipefail

asset="rustfs-linux-x86_64-gnu-v${BASELINE_TAG}.zip"
mkdir -p "$RUNNER_TEMP/rustfs-dl" "$RUNNER_TEMP/rustfs-old" "$RUNNER_TEMP/rustfs-bin"
gh release download "$BASELINE_TAG" --repo rustfs/rustfs --pattern "$asset" --dir "$RUNNER_TEMP/rustfs-dl"
unzip -q -o "$RUNNER_TEMP/rustfs-dl/$asset" -d "$RUNNER_TEMP/rustfs-dl/x"
old="$(find "$RUNNER_TEMP/rustfs-dl/x" -type f -name rustfs | head -n1)"
test -n "$old"
cp "$old" "$RUNNER_TEMP/rustfs-old/rustfs"

found=""
while read -r id sha; do
  if gh run download "$id" --repo "$GITHUB_REPOSITORY" \
      --name rustfs-branch-binary --dir "$RUNNER_TEMP/rustfs-bin" 2>/dev/null; then
    found="$id $sha"
    break
  fi
done < <(gh run list --repo "$GITHUB_REPOSITORY" --workflow cifs-matrix.yml \
  --branch cifs-compat --limit 30 --json databaseId,headSha \
  --jq '.[] | "\(.databaseId) \(.headSha)"')
test -n "$found"
echo "baseline: $BASELINE_TAG, branch binary from run/commit: $found" | tee -a "$GITHUB_STEP_SUMMARY"
chmod +x "$RUNNER_TEMP/rustfs-old/rustfs" "$RUNNER_TEMP/rustfs-bin/rustfs"
