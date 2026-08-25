#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# Functional tests for scripts/environment.
#
# Hermetic: builds a fake group tree with a stub conda, so no real conda install
# and no /groups/sterling are needed. The file hardcodes the group root, so a copy
# is made with that root pointed at the sandbox.
#
# Each test pins behaviour that was wrong at least once, or that is easy to break:
#
#   1 sourcing is clean       - stdout output or a cd here corrupts scp/rsync/sftp,
#                               because bash reads ~/.bashrc for ssh-run commands
#   2 strict callers          - sourcing must not abort a shell running `set -u`
#   3 unknown cluster         - must warn, not silently skip the whole HPC block
#   4 CONDA_ROOT override     - a value the user exported must survive
#   5 env discovery           - the colon-separated CONDA_ENVS_PATH must be split;
#                               quoting it as one path made this fallback dead
#   6 name matching           - env names are literals, not regexes
#   7 activate behaviour      - refuses base, activates what exists
#
# Usage: tests/test-environment.sh
# ------------------------------------------------------------------------------
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT

# --- sandbox: fake group tree, stub conda, fake HOME --------------------------
GROUP="$T/group"
CONDA="$GROUP/software-tools/miniconda"
mkdir -p "$CONDA/etc/profile.d" "$CONDA/envs" "$GROUP/mfshome/$USER/envs" "$GROUP/scripts"
mkdir -p "$T/home/.conda"

# stub conda: enough for `activate` to call, records what it was asked for
cat > "$CONDA/etc/profile.d/conda.sh" <<'STUB'
conda() {
    case "${1:-}" in
        activate) export CONDA_PREFIX="activated:${2:-}"; return 0 ;;
        *)        return 0 ;;
    esac
}
STUB

# environments: one in the group mfshome (registered), one only on disk
mkdir -p "$GROUP/mfshome/$USER/envs/registered/conda-meta"
mkdir -p "$GROUP/mfshome/$USER/envs/unregistered/conda-meta"
mkdir -p "$GROUP/mfshome/$USER/envs/dot.name/conda-meta"
echo "$GROUP/mfshome/$USER/envs/registered" > "$T/home/.conda/environments.txt"

# a copy of the file with the group root pointed at the sandbox
sed -e "s|^G2_STERLING_GROUP=.*|G2_STERLING_GROUP=\"$GROUP\"|" \
    -e "s|^JUNO_STERLING_GROUP=.*|JUNO_STERLING_GROUP=\"$GROUP\"|" \
    "$REPO/scripts/environment" > "$T/environment"

# run a snippet in a clean shell with the sandbox in place
run() {  # run <extra-env> <code>
    env -i HOME="$T/home" PATH="$PATH" USER="$USER" TERM=dumb \
        bash -c "$1 . '$T/environment' >/dev/null 2>&1; $2"
}

echo "== 1/7 sourcing is clean in a non-interactive shell =="
out=$(env -i HOME="$T/home" PATH="$PATH" USER="$USER" \
      bash -c "unset PS1; CLUSTER_NAME=g2; . '$T/environment'" 2>/dev/null)
check "nothing on stdout" "${out:-<empty>}" "<empty>"
cwd=$(env -i HOME="$T/home" PATH="$PATH" USER="$USER" \
      bash -c "cd /tmp; unset PS1; CLUSTER_NAME=g2; . '$T/environment' >/dev/null 2>&1; pwd")
check "working directory unchanged" "$cwd" "/tmp"

echo "== 2/7 sourcing survives a caller running set -u =="
rc=$(env -i HOME="$T/home" PATH="$PATH" USER="$USER" \
     bash -c "set -u; PS1='\$ '; CLUSTER_NAME=g2; . '$T/environment' >/dev/null 2>&1; echo \$?")
check "no unbound-variable abort" "$rc" "0"
rc=$(env -i HOME="$T/home" PATH="$PATH" USER="$USER" \
     bash -c "set -u; PS1='\$ '; . '$T/environment' >/dev/null 2>&1; echo \$?")
check "also with CLUSTER_NAME unset" "$rc" "0"

echo "== 3/7 an unrecognised cluster warns instead of silently skipping =="
err=$(env -i HOME="$T/home" PATH="$PATH" USER="$USER" \
      bash -c "PS1='\$ '; CLUSTER_NAME=nosuchcluster; . '$T/environment'" 2>&1 >/dev/null)
check "warns on stderr" "$(printf '%s' "$err" | grep -c 'Unknown CLUSTER_NAME')" "1"

echo "== 4/7 a user-exported CONDA_ROOT is respected =="
got=$(env -i HOME="$T/home" PATH="$PATH" USER="$USER" \
      bash -c "export CONDA_ROOT=/my/own/conda; PS1='\$ '; CLUSTER_NAME=g2; . '$T/environment' >/dev/null 2>&1; echo \$CONDA_ROOT")
check "kept on a known cluster" "$got" "/my/own/conda"
got=$(env -i HOME="$T/home" PATH="$PATH" USER="$USER" \
      bash -c "export CONDA_ROOT=/my/own/conda; PS1='\$ '; CLUSTER_NAME=nosuch; . '$T/environment' >/dev/null 2>&1; echo \$CONDA_ROOT")
check "kept on an unknown cluster" "$got" "/my/own/conda"
got=$(env -i HOME="$T/home" PATH="$PATH" USER="$USER" \
      bash -c "PS1='\$ '; CLUSTER_NAME=g2; . '$T/environment' >/dev/null 2>&1; echo \$CONDA_ROOT")
check "cluster default still applies when unset" "$got" "$CONDA"

echo "== 5/7 the colon-separated CONDA_ENVS_PATH is split, not treated as one path =="
# hide the registry so ONLY the filesystem fallback can find anything
mv "$T/home/.conda/environments.txt" "$T/home/.conda/environments.txt.off"
n=$(run "PS1='\$ '; CLUSTER_NAME=g2;" "conda_fast_env_list | wc -l")
check "fallback finds on-disk envs" "$([ "$n" -ge 3 ] && echo y || echo n)" "y"
mv "$T/home/.conda/environments.txt.off" "$T/home/.conda/environments.txt"

echo "== 6/7 env names are matched literally, not as regexes =="
# 'dot.name' exists; 'dotXname' must NOT match it, and a bracket must not error
m=$(run "PS1='\$ '; CLUSTER_NAME=g2;" "conda_fast_env_list | grep -cF '  dot.name '")
check "the real name is found" "$m" "1"
out=$(run "PS1='\$ '; CLUSTER_NAME=g2;" "activate 'dotXname' 2>&1 | grep -c 'not found'")
check "a near-miss name is rejected" "$out" "1"
out=$(run "PS1='\$ '; CLUSTER_NAME=g2;" "activate 'a[b' 2>&1 | grep -c 'not found'")
check "a bracketed name does not break grep" "$out" "1"

echo "== 7/7 activate refuses base and activates what exists =="
out=$(run "PS1='\$ '; CLUSTER_NAME=g2;" "activate base 2>&1 | grep -ci refusing")
check "refuses base" "$out" "1"
out=$(run "PS1='\$ '; CLUSTER_NAME=g2;" "activate registered >/dev/null 2>&1; echo \$CONDA_PREFIX")
check "activates a real env" "$out" "activated:registered"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
