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
#   8 pipefail                - grep -q SIGPIPEd the producer, so a real env
#                               intermittently came back as "not found"
#   9 strict callers, calling - `activate` with no argument aborted on $1
#  10 set -e callers          - grep -v exits 1 when it filters everything away
#  11 CONDA_ROOT is exported  - the documented conda.sh fallback needs it in a
#                               child shell
#  12 no variable leakage     - the fallback loop counter escaped the function
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

# Filler environments. Test 8 needs conda_fast_env_list to still be writing when
# `grep -q` exits on the first line -- with only three environments the producer
# finishes first and the SIGPIPE never happens, so the test would pass against
# the very bug it exists to catch.
for i in $(seq 1 300); do mkdir -p "$GROUP/mfshome/$USER/envs/filler$i/conda-meta"; done

# a copy of the file with the group root pointed at the sandbox
sed -e "s|^G2_STERLING_GROUP=.*|G2_STERLING_GROUP=\"$GROUP\"|" \
    -e "s|^JUNO_STERLING_GROUP=.*|JUNO_STERLING_GROUP=\"$GROUP\"|" \
    "$REPO/scripts/environment" > "$T/environment"

# run a snippet in a clean shell with the sandbox in place
run() {  # run <extra-env> <code>
    env -i HOME="$T/home" PATH="$PATH" USER="$USER" TERM=dumb \
        bash -c "$1 . '$T/environment' >/dev/null 2>&1; $2"
}

echo "== 1/12 sourcing is clean in a non-interactive shell =="
out=$(env -i HOME="$T/home" PATH="$PATH" USER="$USER" \
      bash -c "unset PS1; CLUSTER_NAME=g2; . '$T/environment'" 2>/dev/null)
check "nothing on stdout" "${out:-<empty>}" "<empty>"
cwd=$(env -i HOME="$T/home" PATH="$PATH" USER="$USER" \
      bash -c "cd /tmp; unset PS1; CLUSTER_NAME=g2; . '$T/environment' >/dev/null 2>&1; pwd")
check "working directory unchanged" "$cwd" "/tmp"

echo "== 2/12 sourcing survives a caller running set -u =="
rc=$(env -i HOME="$T/home" PATH="$PATH" USER="$USER" \
     bash -c "set -u; PS1='\$ '; CLUSTER_NAME=g2; . '$T/environment' >/dev/null 2>&1; echo \$?")
check "no unbound-variable abort" "$rc" "0"
rc=$(env -i HOME="$T/home" PATH="$PATH" USER="$USER" \
     bash -c "set -u; PS1='\$ '; . '$T/environment' >/dev/null 2>&1; echo \$?")
check "also with CLUSTER_NAME unset" "$rc" "0"

echo "== 3/12 an unrecognised cluster warns instead of silently skipping =="
err=$(env -i HOME="$T/home" PATH="$PATH" USER="$USER" \
      bash -c "PS1='\$ '; CLUSTER_NAME=nosuchcluster; . '$T/environment'" 2>&1 >/dev/null)
check "warns on stderr" "$(printf '%s' "$err" | grep -c 'Unknown CLUSTER_NAME')" "1"

echo "== 4/12 a user-exported CONDA_ROOT is respected =="
got=$(env -i HOME="$T/home" PATH="$PATH" USER="$USER" \
      bash -c "export CONDA_ROOT=/my/own/conda; PS1='\$ '; CLUSTER_NAME=g2; . '$T/environment' >/dev/null 2>&1; echo \$CONDA_ROOT")
check "kept on a known cluster" "$got" "/my/own/conda"
got=$(env -i HOME="$T/home" PATH="$PATH" USER="$USER" \
      bash -c "export CONDA_ROOT=/my/own/conda; PS1='\$ '; CLUSTER_NAME=nosuch; . '$T/environment' >/dev/null 2>&1; echo \$CONDA_ROOT")
check "kept on an unknown cluster" "$got" "/my/own/conda"
got=$(env -i HOME="$T/home" PATH="$PATH" USER="$USER" \
      bash -c "PS1='\$ '; CLUSTER_NAME=g2; . '$T/environment' >/dev/null 2>&1; echo \$CONDA_ROOT")
check "cluster default still applies when unset" "$got" "$CONDA"

echo "== 5/12 the colon-separated CONDA_ENVS_PATH is split, not treated as one path =="
# hide the registry so ONLY the filesystem fallback can find anything
mv "$T/home/.conda/environments.txt" "$T/home/.conda/environments.txt.off"
n=$(run "PS1='\$ '; CLUSTER_NAME=g2;" "conda_fast_env_list | wc -l")
check "fallback finds on-disk envs" "$([ "$n" -ge 3 ] && echo y || echo n)" "y"
mv "$T/home/.conda/environments.txt.off" "$T/home/.conda/environments.txt"

echo "== 6/12 env names are matched literally, not as regexes =="
# 'dot.name' exists; 'dotXname' must NOT match it, and a bracket must not error
m=$(run "PS1='\$ '; CLUSTER_NAME=g2;" "conda_fast_env_list | grep -cF '  dot.name '")
check "the real name is found" "$m" "1"
out=$(run "PS1='\$ '; CLUSTER_NAME=g2;" "activate 'dotXname' 2>&1 | grep -c 'not found'")
check "a near-miss name is rejected" "$out" "1"
out=$(run "PS1='\$ '; CLUSTER_NAME=g2;" "activate 'a[b' 2>&1 | grep -c 'not found'")
check "a bracketed name does not break grep" "$out" "1"

echo "== 7/12 activate refuses base and activates what exists =="
out=$(run "PS1='\$ '; CLUSTER_NAME=g2;" "activate base 2>&1 | grep -ci refusing")
check "refuses base" "$out" "1"
out=$(run "PS1='\$ '; CLUSTER_NAME=g2;" "activate registered >/dev/null 2>&1; echo \$CONDA_PREFIX")
check "activates a real env" "$out" "activated:registered"

echo "== 8/12 a real environment activates under set -o pipefail =="
# `grep -q` exits at the first match and SIGPIPEs conda_fast_env_list, which
# under pipefail failed the pipeline. It is a race, so one run proves nothing.
fails=0
for _ in $(seq 20); do
    got=$(run "PS1='\$ '; CLUSTER_NAME=g2;" "set -o pipefail; activate registered >/dev/null 2>&1; echo \$CONDA_PREFIX")
    [ "$got" = "activated:registered" ] || fails=$((fails+1))
done
check "20 consecutive runs all activate" "$fails" "0"

echo "== 9/12 activate with no argument survives set -u =="
rc=$(run "set -u; PS1='\$ '; CLUSTER_NAME=g2;" "activate >/dev/null 2>&1; echo \$?")
check "no unbound-variable abort on \$1" "$rc" "0"

echo "== 10/12 a base-only listing does not kill a set -e caller =="
# a HOME with no registry and no env dirs, so the listing is empty and the
# `grep -v` that drops base filters every line away
mkdir -p "$T/emptyhome"
# CONDA_ENVS_PATH must point away from the sandbox envs too, or the listing is
# not empty and grep -v succeeds.
out=$(env -i HOME="$T/emptyhome" PATH="$PATH" USER="$USER" CONDA_ENVS_PATH="$T/no-such-envs" \
      bash -c "set -e; PS1='\$ '; CLUSTER_NAME=g2; . '$T/environment' >/dev/null 2>&1
               activate >/dev/null 2>&1; echo REACHED" 2>/dev/null)
check "caller reaches the next statement" "${out:-<aborted>}" "REACHED"

echo "== 11/12 CONDA_ROOT reaches a child shell =="
got=$(run "PS1='\$ '; CLUSTER_NAME=g2;" "bash -c 'echo \${CONDA_ROOT:-EMPTY}'")
check "exported, like CONDA_ENVS_PATH" "$got" "$CONDA"

echo "== 12/12 conda_fast_env_list leaks nothing into the caller =="
got=$(run "PS1='\$ '; CLUSTER_NAME=g2;" "conda_fast_env_list >/dev/null; echo \${envpath:-unset}")
check "envpath stays local" "$got" "unset"


echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
