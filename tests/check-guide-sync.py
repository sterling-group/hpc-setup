#!/usr/bin/env python3
"""Fail if a guide's Markdown and LaTeX renderings have drifted apart.

Every guide ships twice: a README.md that GitHub renders, and a .tex that becomes
the PDF. They are edited by hand, independently, and they have drifted before:

  * the .tex told readers to install `scripts/cronscript`, a file that has never
    existed, while the README had been corrected to `crontab-backup`;
  * the .tex's "Install the cron job" section lacked the git-clone instructions
    entirely, so a PDF reader who cloned the repo had no working path;
  * the IQmol guide said "may need to be done if prompted" in Markdown and "have to
    be done every time you start IQmol" in LaTeX - flatly contradictory.

Two checks, neither of which needs the two files to be textually identical:

  facts      - paths, hostnames, URLs, flags, #SBATCH lines, cron lines and
               quantities must appear in both. \\lstinputlisting is resolved first,
               so a .tex that includes a script is compared against a .md that
               embeds it.
  structure  - both must contain the same sections, in the same order.

LIMIT, stated plainly: this does NOT compare prose. The third example above - two
renderings making contradictory claims in ordinary sentences - would pass this
check. Catching that reliably needs a human reading both, or a diff of the rendered
output. What this gate does catch is the class that actually recurs: a command,
path, flag or whole section that exists on one side and not the other.

Usage: tests/check-guide-sync.py
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
PAIRS = [
    ("ssh-key", "guides/ssh-key-guide/README.md", "guides/ssh-key-guide/ssh-key-guide.tex"),
    ("iqmol", "guides/iqmol-guide/README.md", "guides/iqmol-guide/IQmol-guide.tex"),
    (
        "rclone-backup",
        "guides/rclone-backup-guide/README.md",
        "guides/rclone-backup-guide/rclone-backup-guide.tex",
    ),
]

FACT_PATTERNS = {
    "path": re.compile(r"/(?:home|groups|tmp|usr|opt|Users)/[A-Za-z0-9_.$/*~-]+"),
    "host": re.compile(r"\b[a-z0-9][a-z0-9-]*\.(?:circ\.utdallas\.edu|rclone\.org)\b"),
    "url": re.compile(r"https?://[A-Za-z0-9./_-]+"),
    "flag": re.compile(r"(?<![-\w])--[a-z][a-z0-9-]+"),
    "sbatch": re.compile(r"#SBATCH[^\n]*"),
    "module": re.compile(r"module (?:purge|load [A-Za-z0-9/._-]+)"),
    "quantity": re.compile(r"\b\d+ ?(?:hours|CPUs|days)\b"),
    "cronline": re.compile(r"^\s*\d+ \d+ \* \* \*.*$", re.M),
}

# Markdown carries a hand-written contents list; LaTeX generates it.
MD_ONLY_SECTIONS = {"contents of table"}


def resolve_includes(tex, base):
    def sub(m):
        target = (base / m.group(1)).resolve()
        return target.read_text() if target.exists() else m.group(0)

    return re.sub(r"\\lstinputlisting\[[^\]]*\]\{([^}]+)\}", sub, tex)


def normalise(text, is_tex):
    if is_tex:
        text = re.sub(r"\\href\{[^}]*\}\{([^}]*)\}", r"\1", text)
        text = re.sub(r"\\verb\|([^|]*)\|", r"\1", text)
        text = re.sub(r"\\(?:texttt|textbf|emph|item)\b", " ", text)
        text = re.sub(r"\\[a-zA-Z]+\*?", " ", text)
        text = text.replace("\\_", "_").replace("\\$", "$").replace("\\#", "#")
        text = re.sub(r"[{}]", "", text)
    else:
        fences = []

        def stash(m):
            fences.append(m.group(0))
            return f"\x00F{len(fences) - 1}\x00"

        text = re.sub(r"```.*?```", stash, text, flags=re.S)
        text = re.sub(r"!\[[^\]]*\]\([^)]*\)", " ", text)
        text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)
        text = re.sub(r"^[ \t]*#+", " ", text, flags=re.M)
        text = re.sub(r"[`*>]", " ", text)
        for i, f in enumerate(fences):
            text = text.replace(f"\x00F{i}\x00", f)
    return re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}", r"$\1", text)


def facts(text):
    return {
        name: {m.group(0).rstrip(".,);:").strip() for m in pat.finditer(text)}
        for name, pat in FACT_PATTERNS.items()
    }


def section_key(title):
    title = re.sub(r"\\[a-zA-Z]+", " ", title)
    title = re.sub(r"[^A-Za-z0-9 ]", " ", title)
    return " ".join(sorted(w.lower() for w in title.split() if len(w) > 1))


def md_sections(text):
    text = re.sub(r"```.*?```", "", text, flags=re.S)
    return [m.group(2).strip() for m in re.finditer(r"^(#{2,3})\s+(.+)$", text, re.M)]


def tex_sections(text):
    return [m.group(2).strip() for m in re.finditer(r"\\(section|subsection)\*?\{(.+?)\}\s*$", text, re.M)]


problems = []
for name, md_rel, tex_rel in PAIRS:
    md_raw = (ROOT / md_rel).read_text()
    tex_raw = (ROOT / tex_rel).read_text()
    md = normalise(md_raw, is_tex=False)
    tex = normalise(resolve_includes(tex_raw, (ROOT / tex_rel).parent), is_tex=True)

    fm, ft = facts(md), facts(tex)
    for cat in FACT_PATTERNS:
        for v in sorted(fm[cat] - ft[cat]):
            problems.append(f"{name}: {cat} '{v}' is in {md_rel} but not {tex_rel}")
        for v in sorted(ft[cat] - fm[cat]):
            problems.append(f"{name}: {cat} '{v}' is in {tex_rel} but not {md_rel}")

    md_s = [(h, section_key(h)) for h in md_sections(md_raw) if section_key(h) not in MD_ONLY_SECTIONS]
    tex_s = [(h, section_key(h)) for h in tex_sections(tex_raw)]
    mk = {k for _, k in md_s}
    tk = {k for _, k in tex_s}
    for h, k in md_s:
        if k not in tk:
            problems.append(f"{name}: section '{h}' is in {md_rel} but not {tex_rel}")
    for h, k in tex_s:
        if k not in mk:
            problems.append(f"{name}: section '{h}' is in {tex_rel} but not {md_rel}")
    if [k for _, k in md_s if k in tk] != [k for _, k in tex_s if k in mk]:
        problems.append(f"{name}: shared sections appear in a different order")

for p in problems:
    print(f"::error::{p}")
print(f"{len(problems)} problem(s)")
sys.exit(1 if problems else 0)
