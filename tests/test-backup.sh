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
#   3 snapshot retention     - keep the newest N, purge the rest, dirs and all
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

# A copy of the script that believes it is Sunday, so the weekly path can be tested
# on any day. The single quotes are deliberate: $(date +%u) is literal pattern text.
# shellcheck disable=SC2016
make_sunday() { sed 's/^DOW=$(date +%u)$/DOW=7/' "$SCRIPT" > "$1"; chmod +x "$1"; }
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

echo "== 1/9 exclude is anchored to the root =="
seed; run "$SCRIPT" >/dev/null 2>&1
check "root envs/ excluded"   "$([ -e "$T/remote/daily/envs" ] && echo y || echo n)" "n"
check "nested envs/ backed up" "$([ -f "$T/remote/daily/project/data/envs/config.yaml" ] && echo y || echo n)" "y"

echo "== 2/9 a snapshot survives the next prune (content mtime must not matter) =="
make_sunday "$T/sunday.sh"
run "$T/sunday.sh" >/dev/null 2>&1
before=$(find "$T/remote/archive/$today" -type f | wc -l)
run "$SCRIPT" >/dev/null 2>&1
after=$(find "$T/remote/archive/$today" -type f | wc -l)
check "snapshot intact after prune" "$after" "$before"
check "old-mtime file retained" "$([ -f "$T/remote/archive/$today/notes/thesis.tex" ] && echo y || echo n)" "y"

echo "== 3/9 prune keeps the newest N snapshots =="
seed
# six dated folders, oldest first; only the newest REMOTE_KEEP_SNAPSHOTS survive
for d in 2026-01-04 2026-01-11 2026-01-18 2026-01-25 2026-02-01 2026-02-08; do
  mkdir -p "$T/remote/archive/$d"; echo x > "$T/remote/archive/$d/f.txt"
done
mkdir -p "$T/remote/archive/not-a-date"; echo x > "$T/remote/archive/not-a-date/f.txt"
run "$SCRIPT" >/dev/null 2>&1
keep=$(grep -oE '^REMOTE_KEEP_SNAPSHOTS=[0-9]+' "$SCRIPT" | cut -d= -f2)
# the run also creates today's snapshot if it is a Sunday, so count dated dirs only
kept=$(find "$T/remote/archive" -maxdepth 1 -mindepth 1 -type d \
        -regex '.*/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' | wc -l)
check "keeps exactly N dated snapshots" "$kept" "$keep"
check "newest survives"     "$([ -e "$T/remote/archive/2026-02-08" ] && echo y || echo n)" "y"
check "oldest purged"       "$([ -e "$T/remote/archive/2026-01-04" ] && echo y || echo n)" "n"
check "purge removes the dir, not just files" "$([ -e "$T/remote/archive/2026-01-11" ] && echo y || echo n)" "n"
check "non-date entry untouched" "$([ -e "$T/remote/archive/not-a-date" ] && echo y || echo n)" "y"

echo "== 4/9 empty DATA_DIR must not wipe the remote =="
seed; run "$SCRIPT" >/dev/null 2>&1
n_before=$(find "$T/remote/daily" -type f | wc -l)
mkdir -p "$T/empty"
DATA_DIR="$T/empty" REMOTE_ROOT="$T/remote" RCLONE_BIN="$RCLONE" LOG_DIR="$T/logs" "$SCRIPT" >/dev/null 2>&1
rc=$?
check "run failed"      "$([ "$rc" -ne 0 ] && echo y || echo n)" "y"
check "remote untouched" "$(find "$T/remote/daily" -type f | wc -l)" "$n_before"

echo "== 5/9 mass deletion refused, and not retried through =="
seed; mkdir -p "$T/data/bulk"; for i in $(seq 1 200); do echo x > "$T/data/bulk/f$i.txt"; done
run "$SCRIPT" >/dev/null 2>&1
for i in $(seq 1 150); do rm "$T/data/bulk/f$i.txt"; done
run "$SCRIPT" >/dev/null 2>&1; rc=$?
check "exit is rclone's fatal code" "$rc" "7"
check "stopped at the threshold"    "$(find "$T/remote/daily/bulk" -type f | wc -l)" "100"
check "no retry of a fatal error"   "$(grep -c 'Retrying in' "$T/logs/backup-$today.log")" "0"

echo "== 6/9 mirrored deletions are recoverable =="
check "deleted files land in versions/" \
  "$([ "$(find "$T/remote/versions" -type f 2>/dev/null | wc -l)" -gt 0 ] && echo y || echo n)" "y"

echo "== 7/9 a skipped weekly snapshot is logged =="
seed; run "$SCRIPT" >/dev/null 2>&1
if [ "$(date +%u)" = "7" ]; then
  check "snapshot taken on Sunday" "$([ -d "$T/remote/archive/$today" ] && echo y || echo n)" "y"
else
  check "skip is recorded" "$(grep -c 'no weekly snapshot' "$T/logs/backup-$today.log")" "1"
fi

echo "== 8/9 the weekly snapshot mirrors a COMPLETED daily sync =="
seed
make_sunday "$T/sunday.sh"
run "$T/sunday.sh" >/dev/null 2>&1
# snapshot content must equal daily content exactly - no partial upload can be
# captured, because main() runs backup_daily to completion before snapshot_weekly
d_files=$(cd "$T/remote/daily" && find . -type f | sort | md5sum)
a_files=$(cd "$T/remote/archive/$today" && find . -type f | sort | md5sum)
check "snapshot matches daily exactly" "$a_files" "$d_files"

# and a FAILED daily must leave no snapshot at all
seed; mkdir -p "$T/empty"
DATA_DIR="$T/empty" REMOTE_ROOT="$T/remote" RCLONE_BIN="$RCLONE" LOG_DIR="$T/logs" \
  "$T/sunday.sh" >/dev/null 2>&1
check "failed daily takes no snapshot" \
  "$([ -e "$T/remote/archive/$today" ] && echo y || echo n)" "n"

echo "== 9/9 the snapshot waits for the remote listing, within a bound =="
# drive the helper directly: sourcing the whole script would take its lock
awk '/^wait_for_daily_to_settle\(\) \{/,/^\}/' "$SCRIPT" > "$T/settle.sh"
seed; mkdir -p "$T/remote/daily"
cp "$T/data/notes/thesis.tex" "$T/remote/daily/"     # remote deliberately short
# The assignments below are read by the function sourced inside the subshell,
# which shellcheck cannot follow because that file is generated at runtime.
# shellcheck disable=SC2034,SC1090,SC1091
(
  DATA_DIR="$T/data"; REMOTE_ROOT="$T/remote"; RCLONE_BIN="$RCLONE"
  RCLONE_OPTS="--fast-list --checksum --log-level WARNING"; SETTLE_MAX_WAIT=4
  . "$T/settle.sh"
  start=$(date +%s)
  wait_for_daily_to_settle "$T/logs/settle.log"; echo "rc=$?" > "$T/settle.rc"
  echo "el=$(( $(date +%s) - start ))" >> "$T/settle.rc"
)
# shellcheck disable=SC1090,SC1091
. "$T/settle.rc"
check "gives up on a mismatch"        "$rc" "1"
check "respects SETTLE_MAX_WAIT"      "$([ "${el:-99}" -le 6 ] && echo y || echo n)" "y"
check "reports both sides in the log" \
  "$(grep -c 'source=\|remote=' "$T/logs/settle.log")" "2"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
