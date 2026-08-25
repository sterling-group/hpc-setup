#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# Rebuild the guide PDFs from their .tex sources.
#
# Run this after editing any guides/*/*.tex, or after editing a script the rclone
# guide pulls in with \lstinputlisting (scripts/backup.sh, scripts/crontab-backup).
#
# Two things this gets right that a hand-run pdflatex easily gets wrong:
#   * TWO passes. \tableofcontents needs the first pass to write the .toc and the
#     second to typeset it. A single pass silently produces a PDF with a
#     "Contents" heading and no entries under it.
#   * TEXINPUTS. The guides reference images by bare filename with no
#     \graphicspath, so images/ must be on the input path or the build fails.
#
# Usage: guides/build-pdfs.sh [guide-dir ...]     (default: all of them)
# ------------------------------------------------------------------------------
set -euo pipefail

GUIDES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v pdflatex >/dev/null || { echo "pdflatex not found" >&2; exit 1; }

targets=("$@")
if [ ${#targets[@]} -eq 0 ]; then
    targets=("$GUIDES_DIR"/*/)
fi

status=0
for dir in "${targets[@]}"; do
    dir="${dir%/}"
    tex=$(find "$dir" -maxdepth 1 -name '*.tex' -print -quit)
    [ -n "$tex" ] || continue
    name=$(basename "$tex" .tex)
    work=$(mktemp -d)

    echo "==> $name"
    for pass in 1 2; do
        if ! (cd "$dir" && TEXINPUTS=".:./images//:" pdflatex \
                -interaction=nonstopmode -halt-on-error \
                -output-directory="$work" "$(basename "$tex")" >"$work/pass$pass.log" 2>&1); then
            echo "    FAILED on pass $pass; last lines:" >&2
            tail -15 "$work/pass$pass.log" >&2
            status=1
            break
        fi
    done

    if [ -f "$work/$name.pdf" ]; then
        entries=$(grep -c '\\contentsline' "$work/$name.toc" 2>/dev/null || echo 0)
        expected=$(grep -cE '^\s*\\(sub)?section\{' "$tex" || true)
        if [ "$entries" -ne "$expected" ]; then
            echo "    WARNING: $entries TOC entries for $expected sections" >&2
            status=1
        fi
        cp "$work/$name.pdf" "$dir/$name.pdf"
        echo "    wrote $dir/$name.pdf ($entries TOC entries)"
    fi
    rm -rf "$work"
done

exit $status
