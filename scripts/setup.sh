#!/bin/bash                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                
# Author:
#     Markus G. S. Weiss
# Date:
#     2025-01-15

CLUSTER_NAME=$(scontrol show config | grep -oP '^ClusterName\s*=\s*\K\S+' || echo 'unknown')

# Define paths based on cluster name
if [[ "$CLUSTER_NAME" == "g2" ]]; then
    MFSHOME="/groups/sterling/mfshome/$USER"
    SETUP_SCRIPT="/groups/sterling/setup/environment"
elif [[ "$CLUSTER_NAME" == "juno" ]]; then
    MFSHOME="/groups/sterling/mfshome/$USER"
    SETUP_SCRIPT="/groups/sterling/setup/environment"
else
    echo "Unknown cluster name: $CLUSTER_NAME"
    exit 1
fi

# Check if the directory exists
if [ ! -d "$MFSHOME" ]; then
    echo "Creating directory: $MFSHOME"
    mkdir -p "$MFSHOME"
    chmod 750 "$MFSHOME"
    echo "Directory created and permissions set to 750."
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
Usage: bash setup_bashrc.sh [OPTIONS]

Options:
  --help      Display this help message and exit.
  --remove    Remove the environment setup from your shell configuration file.

This script adds or removes a sourcing block for $SETUP_SCRIPT in your shell's initialization file ($INIT_FILE).
A backup of your original file will be saved with a .bak extension.
EOF
    exit 0
}

# Parse command-line arguments
if [[ $# -gt 1 ]]; then
    show_help
fi

case "$1" in
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

# Function to add the sourcing block with a preceding blank line
add_sourcing_block() {
    if [ ! -f "$SETUP_SCRIPT" ]; then
        echo "Error: $SETUP_SCRIPT does not exist."
        exit 1
    fi  

    if grep -Fxq "$START_MARKER" "$INIT_FILE"; then
        echo "Environment setup already exists in $INIT_FILE."
    else
        echo "Adding environment setup to $INIT_FILE..."
        cp "$INIT_FILE" "$INIT_FILE.bak"
        {
            echo
            echo "$START_MARKER"
            echo "if [ -f \"$SETUP_SCRIPT\" ]; then"
            echo "    export CLUSTER_NAME=\"$CLUSTER_NAME\""
            echo "    . \"$SETUP_SCRIPT\""
            echo "fi"
            echo "$END_MARKER"
        } >> "$INIT_FILE"
        echo "Setup added successfully."
        echo "A backup of your original file is saved as ${INIT_FILE}.bak"
        CHANGE_MADE=1
    fi  
}

# Function to remove the sourcing block without deleting other blank lines
remove_sourcing_block() {
    if grep -Fxq "$START_MARKER" "$INIT_FILE"; then
        echo "Removing environment setup from $INIT_FILE..."
        cp "$INIT_FILE" "$INIT_FILE.bak"

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

        echo "Sourcing block removed successfully."
        echo "A backup of your original file is saved as ${INIT_FILE}.bak"
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
