#!/usr/bin/env python3
"""Fail if a guide's embedded copy of a script has drifted from the real file.

The rclone guide reproduces scripts/backup.sh and scripts/crontab-backup inline so
readers can see them without leaving the page. Every one of those copies has
diverged from the original at least once, silently:

  * the LaTeX copy carried --dry-run inside RCLONE_OPTS, so a backup built from
    the published PDF transferred nothing while logging success;
  * the Markdown copy lost the closing quote on a variable default and stopped
    being valid bash at all;
  * the LaTeX copy told readers to install scripts/cronscript, which never existed;
  * an --exclude fix landed on the script and on neither copy.

The .tex now uses \\lstinputlisting and cannot drift. The Markdown copy is checked
here, byte for byte.
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GUIDE = ROOT / "guides/rclone-backup-guide/README.md"
TEX = ROOT / "guides/rclone-backup-guide/rclone-backup-guide.tex"

# (heading anchor, fence language, real file)
BLOCKS = [
    (r"### A\) `backup\.sh`", "bash", ROOT / "scripts/backup.sh"),
    (r"### B\) `crontab-backup`", "cron", ROOT / "scripts/crontab-backup"),
]

failures = []
text = GUIDE.read_text()

for heading, lang, real in BLOCKS:
    m = re.search(heading + r"\n```" + lang + r"\n(.*?)\n```", text, re.S)
    if not m:
        failures.append(f"{GUIDE.name}: no embedded {real.name} block found")
        continue
    embedded = m.group(1)
    expected = real.read_text().rstrip("\n")
    if embedded != expected:
        failures.append(
            f"{GUIDE.name}: embedded copy of {real.name} differs from the real file. "
            f"Re-sync it, do not hand-edit the copy."
        )
    if real.suffix == ".sh":
        with tempfile.NamedTemporaryFile("w", suffix=".sh") as fh:
            fh.write(embedded)
            fh.flush()
            if subprocess.run(["bash", "-n", fh.name], capture_output=True).returncode:
                failures.append(f"{GUIDE.name}: embedded {real.name} is not valid bash")
        if "--dry-run" in embedded:
            failures.append(
                f"{GUIDE.name}: embedded {real.name} contains --dry-run; it would back up nothing"
            )

# The LaTeX source must include the real files rather than copying them.
tex = TEX.read_text()
for real in ("scripts/backup.sh", "scripts/crontab-backup"):
    if f"lstinputlisting[style=custombash]{{../../{real}}}" not in tex:
        failures.append(f"{TEX.name}: expected \\lstinputlisting of {real}")
if "#!/usr/bin/env bash" in tex:
    failures.append(f"{TEX.name}: contains an inline copy of a script; use \\lstinputlisting")

for f in failures:
    print(f"::error::{f}")
print(f"{len(failures)} problem(s)")
sys.exit(1 if failures else 0)
