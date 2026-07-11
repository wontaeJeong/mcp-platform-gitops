#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

repo="$TMP_DIR/repo"
mkdir "$repo"
GIT_MASTER=1 git -C "$repo" init --quiet
printf 'ignored.txt\n' >"$repo/.gitignore"
printf 'original\n' >"$repo/tracked.txt"
printf '#!/bin/sh\nexit 0\n' >"$repo/tool.sh"
chmod 755 "$repo/tool.sh"
GIT_MASTER=1 git -C "$repo" add .
GIT_MASTER=1 git -C "$repo" -c user.name=Test -c user.email=test@example.invalid commit --quiet -m initial

identifier() {
  python3 "$ROOT_DIR/scripts/source-identifier.py" "$repo"
}

clean="$(identifier)"
head="$(GIT_MASTER=1 git -C "$repo" rev-parse HEAD)"
[ "$clean" = "$head" ]
[[ "$clean" =~ ^[0-9a-f]{40}$ ]]

printf 'modified\n' >"$repo/tracked.txt"
modified="$(identifier)"
[[ "$modified" =~ ^[0-9a-f]{64}$ ]]
[ "$modified" != "$clean" ]

printf 'original\n' >"$repo/tracked.txt"
printf 'untracked\n' >"$repo/untracked.txt"
untracked="$(identifier)"
[[ "$untracked" =~ ^[0-9a-f]{64}$ ]]
[ "$untracked" != "$modified" ]
rm "$repo/untracked.txt"

printf 'ignored\n' >"$repo/ignored.txt"
[ "$(identifier)" = "$clean" ]
rm "$repo/ignored.txt"

rm "$repo/tracked.txt"
deleted="$(identifier)"
[[ "$deleted" =~ ^[0-9a-f]{64}$ ]]
[ "$deleted" != "$clean" ]
printf 'original\n' >"$repo/tracked.txt"

mv "$repo/tracked.txt" "$repo/renamed.txt"
renamed="$(identifier)"
[[ "$renamed" =~ ^[0-9a-f]{64}$ ]]
[ "$renamed" != "$deleted" ]
mv "$repo/renamed.txt" "$repo/tracked.txt"

ln -s tracked.txt "$repo/link.txt"
symlinked="$(identifier)"
[[ "$symlinked" =~ ^[0-9a-f]{64}$ ]]
rm "$repo/link.txt"

chmod 644 "$repo/tool.sh"
mode_changed="$(identifier)"
[[ "$mode_changed" =~ ^[0-9a-f]{64}$ ]]
[ "$mode_changed" != "$clean" ]

echo "PASS: source identifiers cover clean, modified, untracked, ignored, deleted, renamed, symlink, and mode states"
