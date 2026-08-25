#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# Functional tests for scripts/setup.sh.
#
# Fully sandboxed: a fake HOME, a stub scontrol, and MFSHOME redirected into a temp
# tree, so nothing real is touched. The script is copied and rewritten to point at
# the sandbox, since it hardcodes the group path.
#
# Each test pins behaviour that was wrong at least once:
#
#   1 add                 - installs the block, backs the file up
#   2 refresh             - re-running must update a stale block, not skip it. The
#                           block bakes in SETUP_SCRIPT, so skipping left a moved
#                           checkout pointing at a path that silently did nothing
#   3 remove              - takes the block out and leaves everything else intact
#   4 unbalanced markers  - a start marker with no end marker must NOT be "removed":
#                           the awk deletes from the marker to EOF, which once cut
#                           an 8-line rc file down to 2
#   5 honest reporting    - no claiming a backup that was not made, and a failed
#                           mkdir must not report success
#   6 argument handling   - --help, unknown options, unknown cluster
#
# Usage: tests/test-setup.sh
# ------------------------------------------------------------------------------
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT
mkdir -p "$T/bin"
# single quotes on purpose: the expansion belongs in the stub, not here
# shellcheck disable=SC2016
printf '#!/bin/sh\necho "ClusterName = ${FAKE_CLUSTER:-g2}"\n' > "$T/bin/scontrol"
chmod +x "$T/bin/scontrol"

SETUP="$T/setup.sh"
sed "s|MFSHOME=\"/groups/sterling/mfshome/\$USER\"|MFSHOME=\"$T/mfs/\$USER\"|g" \
    "$REPO/scripts/setup.sh" > "$SETUP"
chmod +x "$SETUP"
cp "$REPO/scripts/environment" "$T/environment"

fresh_home() {  # fresh_home [rc-contents]
    rm -rf "${T:?}/home" "${T:?}/mfs"; mkdir -p "$T/home"
    if [ $# -gt 0 ]; then printf '%s\n' "$1" > "$T/home/.bashrc"
    else printf '# my precious rc\nalias ll="ls -l"\n' > "$T/home/.bashrc"; fi
}
run() { PATH="$T/bin:$PATH" HOME="$T/home" SHELL=/bin/bash "$SETUP" "$@" 2>&1; }
# grep -c prints 0 AND exits 1 when there are no matches, so guard the file test
# separately rather than with `|| echo 0`, which would print a second zero.
markers() {
    local n=0
    [ -f "$T/home/.bashrc" ] && \
        n=$(grep -c 'Sterling group environment setup' "$T/home/.bashrc" 2>/dev/null || true)
    printf '%s' "${n:-0}"
}

echo "== 1/6 add installs the block =="
fresh_home; out=$(run); rc=$?
check "exits 0"                "$rc" "0"
check "start and end markers"  "$(markers)" "2"
check "backup written"         "$([ -f "$T/home/.bashrc.bak" ] && echo y || echo n)" "y"
check "user content intact"    "$(grep -c 'alias ll' "$T/home/.bashrc")" "1"
check "mfshome created"        "$([ -d "$T/mfs/$USER" ] && echo y || echo n)" "y"

echo "== 2/6 re-running refreshes rather than skipping =="
out=$(run)
check "says it refreshed"      "$(printf '%s' "$out" | grep -ci refresh)" "1"
check "still exactly one block" "$(markers)" "2"
# a stale path in the block must be replaced, not left behind
sed -i 's|^if \[ -f .*environment" \]; then|if [ -f "/OLD/STALE/environment" ]; then|' "$T/home/.bashrc"
run >/dev/null
check "stale path replaced"    "$(grep -c '/OLD/STALE/' "$T/home/.bashrc")" "0"

echo "== 3/6 remove takes the block out and leaves the rest =="
out=$(run --remove)
check "block gone"             "$(markers)" "0"
check "user content intact"    "$(grep -c 'alias ll' "$T/home/.bashrc")" "1"
check "reports removal"        "$(printf '%s' "$out" | grep -ci 'removed successfully')" "1"
out=$(run --remove)
check "second remove is a no-op" "$(printf '%s' "$out" | grep -ci 'no environment setup block')" "1"

echo "== 4/6 an unbalanced marker pair must NOT truncate the file =="
fresh_home '# my precious rc
alias ll="ls -l"
# >>> Sterling group environment setup >>>
if [ -f "/x/environment" ]; then
    . "/x/environment"
fi
export IMPORTANT_VAR=1
alias deploy="make deploy"'
before=$(wc -l < "$T/home/.bashrc")
out=$(run --remove); rc=$?
check "refuses"                "$(printf '%s' "$out" | grep -ci 'refusing to edit')" "1"
check "exits non-zero"         "$([ "$rc" -ne 0 ] && echo y || echo n)" "y"
check "file untouched"         "$(wc -l < "$T/home/.bashrc")" "$before"
check "IMPORTANT_VAR survives" "$(grep -c IMPORTANT_VAR "$T/home/.bashrc")" "1"
check "alias deploy survives"  "$(grep -c 'alias deploy' "$T/home/.bashrc")" "1"

echo "== 5/6 reporting is honest =="
# no init file at all: must not claim a backup was made
fresh_home; rm -f "$T/home/.bashrc"
out=$(run)
check "does not claim a phantom backup" \
  "$(printf '%s' "$out" | grep -c 'backup of your original file is saved')" "0"
check "block still installed"  "$(markers)" "2"
# unwritable mfshome parent: mkdir fails, so the script must fail too
fresh_home; : > "$T/mfs"          # a FILE where the directory should go
out=$(run); rc=$?
check "failed mkdir exits non-zero" "$([ "$rc" -ne 0 ] && echo y || echo n)" "y"
check "does not claim success"      "$(printf '%s' "$out" | grep -c 'permissions set to 750')" "0"
rm -f "$T/mfs"

echo "== 6/6 argument and cluster handling =="
fresh_home
check "--help exits 0"          "$(run --help >/dev/null; echo $?)" "0"
check "--help prints usage"     "$(run --help | grep -ci 'usage:')" "1"
check "unknown option shows help" "$(run --bogus | grep -ci 'usage:')" "1"
out=$(FAKE_CLUSTER=mars PATH="$T/bin:$PATH" HOME="$T/home" SHELL=/bin/bash "$SETUP" 2>&1); rc=$?
check "unknown cluster exits non-zero" "$([ "$rc" -ne 0 ] && echo y || echo n)" "y"
check "unknown cluster is named"       "$(printf '%s' "$out" | grep -c 'mars')" "1"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
