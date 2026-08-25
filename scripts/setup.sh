#!/usr/bin/env bash
#
# This script sets up the HPC environment for Sterling group clusters.
#
# It creates the necessary home directory structure, detects the cluster type,
# and configures shell initialization files to source the Sterling group
# environment setup. Supports both adding and removing the configuration.
#
# Usage:
#     setup.sh [options]
#     
# Options:
#     --help      Display help message and exit
#     --remove    Remove environment setup from shell configuration
#
# Author:
#     Markus G. S. Weiss
# Date:
#     2025-09-27
#

set -eu

CLUSTER_NAME=$(scontrol show config 2>/dev/null | grep -oP '^ClusterName\s*=\s*\K\S+' || echo 'unknown')

# Get script directory for environment file location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETUP_SCRIPT="${SCRIPT_DIR}/environment"

# Define paths based on cluster name
if [ "$CLUSTER_NAME" = "g2" ]; then
    MFSHOME="/groups/sterling/mfshome/$USER"
elif [ "$CLUSTER_NAME" = "juno" ]; then
    MFSHOME="/groups/sterling/mfshome/$USER"
else
    echo "Unknown cluster name: $CLUSTER_NAME"
    exit 1
fi

# Verify environment script exists
[ ! -f "$SETUP_SCRIPT" ] && { echo "Error: Environment script not found: $SETUP_SCRIPT"; exit 1; }

echo "Using environment script: $SETUP_SCRIPT"

# Check if the directory exists
if [ ! -d "$MFSHOME" ]; then
    echo "Creating directory: $MFSHOME"
    if mkdir -p "$MFSHOME" && chmod 750 "$MFSHOME"; then
        echo "Directory created and permissions set to 750."
    else
        echo "Error: could not create $MFSHOME (quota, permissions, or the filesystem is not mounted)." >&2
        echo "Refusing to continue: the environment would load but find nothing there." >&2
        exit 1
    fi
else
    echo "Your home directory already exists: $MFSHOME"
fi

# Unique markers to identify the sourcing block
START_MARKER="# >>> Sterling group environment setup >>>"
END_MARKER="# <<< Sterling group environment setup <<<"

# Determine the shell and initialization file
case "$(basename "$SHELL")" in
    bash)
        INIT_FILE="$HOME/.bashrc"
        ;;
    zsh)
        INIT_FILE="$HOME/.zshrc"
        ;;
    *)  
        echo "Unsupported shell: $(basename "$SHELL"). Please manually source $SETUP_SCRIPT."
        exit 1
        ;;
esac

# Display help message
show_help() {
    cat << EOF
Usage: setup.sh [OPTIONS]

Options:
  --help      Display this help message and exit.
  --remove    Remove the environment setup from your shell configuration file.

This script adds or removes a sourcing block for $SETUP_SCRIPT in your shell's initialization file ($INIT_FILE).
A backup of your original file will be saved with a .bak extension.
EOF
    exit 0
}

# Parse command-line arguments
if [ $# -gt 1 ]; then
    show_help
fi

case "${1:-}" in
    --help)
        show_help
        ;;
    --remove)
        ACTION="remove"
        ;;
    "") 
        ACTION="add"
        ;;
    *)  
        show_help
        ;;
esac

# Refuse to rewrite an init file whose markers do not pair up.
assert_markers_balanced() {
    local starts ends
    starts=$(grep -Fxc "$START_MARKER" "$INIT_FILE" || true)
    ends=$(grep -Fxc "$END_MARKER" "$INIT_FILE" || true)
    if [ "$starts" != "$ends" ]; then
        echo "Error: $INIT_FILE has $starts start marker(s) but $ends end marker(s)." >&2
        echo "Refusing to edit it -- removing an unterminated block would delete everything" >&2
        echo "after the marker. Repair the block by hand, then re-run." >&2
        exit 1
    fi
}

# Function to add the sourcing block with a preceding blank line
add_sourcing_block() {
    if [ ! -f "$SETUP_SCRIPT" ]; then
        echo "Error: $SETUP_SCRIPT does not exist." >&2
        exit 1
    fi

    if grep -Fxq "$START_MARKER" "$INIT_FILE" 2>/dev/null; then
        # Refresh rather than skip: the block bakes in SETUP_SCRIPT and
        # CLUSTER_NAME, which go stale if the checkout moves.
        assert_markers_balanced
        echo "Environment setup already present in $INIT_FILE -- refreshing it..."
        backup_init_file
        strip_sourcing_block
    else
        echo "Adding environment setup to $INIT_FILE..."
        backup_init_file
    fi

    {
        echo
        echo "$START_MARKER"
        echo "if [ -f \"$SETUP_SCRIPT\" ]; then"
        echo "    export CLUSTER_NAME=\"$CLUSTER_NAME\""
        echo "    . \"$SETUP_SCRIPT\""
        echo "fi"
        echo "$END_MARKER"
    } >> "$INIT_FILE"

    echo "Setup written successfully."
    CHANGE_MADE=1
}

# Copy the init file aside, reporting a backup only if one was actually made.
backup_init_file() {
    if [ -f "$INIT_FILE" ]; then
        cp "$INIT_FILE" "$INIT_FILE.bak"
        echo "A backup of your original file is saved as ${INIT_FILE}.bak"
    else
        echo "No existing $INIT_FILE -- creating it (nothing to back up)."
    fi
}

# Strip the marked block from $INIT_FILE via a temp file, so an interrupted run
# cannot leave a half-written shell config. Call assert_markers_balanced first:
# this awk treats a start marker with no end marker as "skip to EOF".
strip_sourcing_block() {
    awk -v start_marker="$START_MARKER" -v end_marker="$END_MARKER" '
    BEGIN { skip = 0; prev_line_set = 0; }
    {
        if (skip) {
            if ($0 == end_marker) {
                skip = 0
                prev_line_set = 0
                next
            }
            next
        }
        if ($0 == start_marker) {
            if (prev_line_set && prev_line == "") {
                # Do not print the blank line before the block
            } else if (prev_line_set) {
                print prev_line
            }
            prev_line_set = 0
            skip = 1
            next
        }
        if (prev_line_set) {
            print prev_line
        }
        prev_line = $0
        prev_line_set = 1
    }
    END {
        if (!skip && prev_line_set) {
            print prev_line
        }
    }' "$INIT_FILE" > "${INIT_FILE}.tmp" && mv "${INIT_FILE}.tmp" "$INIT_FILE"
}

# Function to remove the sourcing block without deleting other blank lines
remove_sourcing_block() {
    if grep -Fxq "$START_MARKER" "$INIT_FILE" 2>/dev/null; then
        assert_markers_balanced
        echo "Removing environment setup from $INIT_FILE..."
        backup_init_file
        strip_sourcing_block
        echo "Sourcing block removed successfully."
        CHANGE_MADE=1
    else
        echo "No environment setup block found in $INIT_FILE."
    fi
}

# Execute the chosen action
CHANGE_MADE=0

if [ "$ACTION" = "add" ]; then
    add_sourcing_block
elif [ "$ACTION" = "remove" ]; then
    remove_sourcing_block
fi

# Prompt to reload the shell configuration if changes were made
if [ $CHANGE_MADE -eq 1 ]; then
    echo "To apply the changes, run: source \"$INIT_FILE\""
fi
