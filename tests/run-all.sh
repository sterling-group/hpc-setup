#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# Run every check in this repository.
#
# There is deliberately no CI: pinned actions need a bot to keep them current,
# which is more upkeep than a repo this size earns. Run this before pushing
# anything that touches scripts/ or guides/ instead.
#
#   tests/run-all.sh
#
# SC2139 is excluded: the aliases in scripts/environment expand at definition
# time on purpose, so the cluster paths resolve once when the file is sourced.
#
# Optional tools are skipped with a note rather than failing the run:
#   rclone      - needed for the backup functional tests
#   ShellCheck  - static analysis of the shell scripts
#   pdflatex    - only needed by guides/build-pdfs.sh, not by these checks
# ------------------------------------------------------------------------------
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "cannot cd to $ROOT" >&2; exit 1; }

pass=0 fail=0 skip=0
run() {  # run <name> <command...>
    local name=$1; shift
    printf '\n=== %s ===\n' "$name"
    if "$@"; then
        pass=$((pass + 1))
    else
        echo "  ^ FAILED"
        fail=$((fail + 1))
    fi
}
note_skip() { printf '\n=== %s ===\n  skipped: %s\n' "$1" "$2"; skip=$((skip + 1)); }

SHELL_FILES=(scripts/backup.sh scripts/setup.sh scripts/environment
             tests/test-backup.sh tests/test-setup.sh tests/test-environment.sh
             tests/run-all.sh guides/build-pdfs.sh)

syntax() {
    local rc=0 f
    for f in "${SHELL_FILES[@]}"; do
        [ -f "$f" ] || continue
        if bash -n "$f"; then printf '  ok   %s\n' "$f"; else rc=1; fi
    done
    return $rc
}
run "shell syntax" syntax

if command -v shellcheck >/dev/null; then
    run "shellcheck" shellcheck -e SC2139 "${SHELL_FILES[@]}"
elif command -v docker >/dev/null; then
    run "shellcheck (via docker)" docker run --rm -v "$ROOT:/mnt:ro" -w /mnt \
        koalaman/shellcheck:stable -e SC2139 "${SHELL_FILES[@]}"
else
    note_skip "shellcheck" "not installed (apt install shellcheck)"
fi

run "documentation hygiene"        python3 tests/check-docs.py
run "embedded script copies"       python3 tests/check-doc-copies.py
run "guide .md vs .tex in sync"    python3 tests/check-guide-sync.py

if command -v rclone >/dev/null; then
    run "backup.sh functional tests" tests/test-backup.sh
else
    note_skip "backup.sh functional tests" "rclone not installed"
fi

# These two are hermetic - they build their own sandbox and stub out conda and
# scontrol, so they need nothing installed.
run "setup.sh functional tests"     tests/test-setup.sh
run "environment functional tests"  tests/test-environment.sh

printf '\n---------------------------------------------\n'
printf '%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
