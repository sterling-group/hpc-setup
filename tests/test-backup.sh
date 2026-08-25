#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# Functional tests for scripts/backup.sh
#
# Runs the real script end to end against a local directory standing in for the
# Box remote, so every assertion exercises actual rclone behaviour rather than a
# mock. Each test pins a defect that shipped at least once:
#
#   1 exclude anchoring      - 'envs/**' matched at any depth and silently
#                              dropped every nested user directory named envs
#   2 snapshot retention     - --min-age pruned by file content mtime, so a
#                              snapshot decayed the day after it was taken
#   3 dated-directory prune  - old snapshots must go, recent ones must stay
#   4 empty-source guard     - an unmounted DATA_DIR must not mirror emptiness
#   5 --max-delete           - a mass deletion must be refused, and retry() must
#                              not grind it through in batches
#   6 --backup-dir           - mirrored deletions must be recoverable
#   7 skip logging           - a non-Sunday run must say so
#
# Usage: tests/test-backup.sh          (needs rclone on PATH)
# ------------------------------------------------------------------------------
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/scripts/backup.sh"
RCLONE="$(command -v rclone || true)"
[ -n "$RCLONE" ] || { echo "SKIP: rclone not on PATH"; exit 0; }

PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
run() { DATA_DIR="$T/data" REMOTE_ROOT="$T/remote" RCLONE_BIN="$RCLONE" LOG_DIR="$T/logs" "$@" ; }
today=$(date +%F)

seed() {
  rm -rf "$T"/{data,remote,logs}; mkdir -p "$T"/{data,remote,logs}
  mkdir -p "$T/data/envs/myconda" "$T/data/project/data/envs" "$T/data/notes"
  echo conda    > "$T/data/envs/myconda/pkg.txt"          # root envs -> excluded
  echo precious > "$T/data/project/data/envs/config.yaml" # nested envs -> KEPT
  echo thesis   > "$T/data/notes/thesis.tex"
  touch -d 2020-01-01 "$T/data/notes/thesis.tex"          # far older than retention
}

echo "== 1/7 exclude is anchored to the root =="
seed; run "$SCRIPT" >/dev/null 2>&1
check "root envs/ excluded"   "$([ -e "$T/remote/daily/envs" ] && echo y || echo n)" "n"
check "nested envs/ backed up" "$([ -f "$T/remote/daily/project/data/envs/config.yaml" ] && echo y || echo n)" "y"

echo "== 2/7 a snapshot survives the next prune (content mtime must not matter) =="
# shellcheck disable=SC2016  # the $(...) is literal sed pattern text, not expansion
sed 's/^DOW=$(date +%u)$/DOW=7/' "$SCRIPT" > "$T/sunday.sh"; chmod +x "$T/sunday.sh"
run "$T/sunday.sh" >/dev/null 2>&1
before=$(find "$T/remote/archive/$today" -type f | wc -l)
run "$SCRIPT" >/dev/null 2>&1
after=$(find "$T/remote/archive/$today" -type f | wc -l)
check "snapshot intact after prune" "$after" "$before"
check "old-mtime file retained" "$([ -f "$T/remote/archive/$today/notes/thesis.tex" ] && echo y || echo n)" "y"

echo "== 3/7 prune selects by directory date =="
seed; mkdir -p "$T/remote/archive/2000-01-01" "$T/remote/archive/$today"
echo x > "$T/remote/archive/2000-01-01/f.txt"; echo x > "$T/remote/archive/$today/f.txt"
run "$SCRIPT" >/dev/null 2>&1
check "stale snapshot purged"  "$([ -e "$T/remote/archive/2000-01-01" ] && echo y || echo n)" "n"
check "recent snapshot kept"   "$([ -e "$T/remote/archive/$today" ] && echo y || echo n)" "y"

echo "== 4/7 empty DATA_DIR must not wipe the remote =="
seed; run "$SCRIPT" >/dev/null 2>&1
n_before=$(find "$T/remote/daily" -type f | wc -l)
mkdir -p "$T/empty"
DATA_DIR="$T/empty" REMOTE_ROOT="$T/remote" RCLONE_BIN="$RCLONE" LOG_DIR="$T/logs" "$SCRIPT" >/dev/null 2>&1
rc=$?
check "run failed"      "$([ "$rc" -ne 0 ] && echo y || echo n)" "y"
check "remote untouched" "$(find "$T/remote/daily" -type f | wc -l)" "$n_before"

echo "== 5/7 mass deletion refused, and not retried through =="
seed; mkdir -p "$T/data/bulk"; for i in $(seq 1 200); do echo x > "$T/data/bulk/f$i.txt"; done
run "$SCRIPT" >/dev/null 2>&1
for i in $(seq 1 150); do rm "$T/data/bulk/f$i.txt"; done
run "$SCRIPT" >/dev/null 2>&1; rc=$?
check "exit is rclone's fatal code" "$rc" "7"
check "stopped at the threshold"    "$(find "$T/remote/daily/bulk" -type f | wc -l)" "100"
check "no retry of a fatal error"   "$(grep -c 'Retrying in' "$T/logs/backup-$today.log")" "0"

echo "== 6/7 mirrored deletions are recoverable =="
check "deleted files land in versions/" \
  "$([ "$(find "$T/remote/versions" -type f 2>/dev/null | wc -l)" -gt 0 ] && echo y || echo n)" "y"

echo "== 7/7 a skipped weekly snapshot is logged =="
seed; run "$SCRIPT" >/dev/null 2>&1
if [ "$(date +%u)" = "7" ]; then
  check "snapshot taken on Sunday" "$([ -d "$T/remote/archive/$today" ] && echo y || echo n)" "y"
else
  check "skip is recorded" "$(grep -c 'no weekly snapshot' "$T/logs/backup-$today.log")" "1"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
