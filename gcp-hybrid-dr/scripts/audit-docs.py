#!/usr/bin/env python3
"""Audit the project documentation for completeness and internal consistency.

Checks four things, and exits non-zero if any of them fails, so it can
gate a CI run:

  1. KEY FACTS      — every headline claim appears in the documents that
                       are supposed to carry it.
  2. STALE NUMBERS  — a superseded figure appears ONLY in a passage that
                       explicitly frames it as superseded.
  3. LINKS          — every relative link resolves, and every document
                       in the repository is linked from the README.
  4. AGREEMENT      — a number that appears in several documents is the
                       SAME number in all of them.

Why this exists
---------------
The project's whole claim is "measured, not estimated". A measured
number that is written down three different ways is worse than no
number at all: a reviewer who finds `$0.53` in one file and `$0.60` in
another has no way to tell which one to believe, and the obvious
conclusion is that none of them were measured.

This ran as a throwaway script during development. It is in the
repository because the check is worth keeping, and because a check
nobody runs is a check that rots.

Usage:
    python3 scripts/audit-docs.py

Exit codes:
    0  everything is consistent
    1  at least one check failed
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# The documents that carry the project's claims. Order is the order they
# are reported in.
DOCS = {
    "README.md": ROOT / "README.md",
    "JOURNEY.md": ROOT / "JOURNEY.md",
    "MISSING.md": ROOT / "MISSING.md",
    "gcp-checklist.md": ROOT / "gcp-checklist.md",
    "docs/01-architecture.md": ROOT / "docs/01-architecture.md",
    "docs/02-cost-analysis.md": ROOT / "docs/02-cost-analysis.md",
    "docs/03-security.md": ROOT / "docs/03-security.md",
    "docs/04-scaling.md": ROOT / "docs/04-scaling.md",
    "docs/05-troubleshooting.md": ROOT / "docs/05-troubleshooting.md",
    "docs/06-measurements.md": ROOT / "docs/06-measurements.md",
    "docs/07-screenshot-runbook.md": ROOT / "docs/07-screenshot-runbook.md",
}

failures: list[str] = []
notes: list[str] = []


def fail(message: str) -> None:
    failures.append(message)
    print(f"  FAIL  {message}")


def ok(message: str) -> None:
    print(f"  ok    {message}")


def rule(title: str) -> None:
    print()
    print("=" * 72)
    print(title)
    print("=" * 72)


# ---------------------------------------------------------------------------
# 1. Key facts
# ---------------------------------------------------------------------------

# (label, regex, documents that must contain it)
KEY_FACTS = [
    ("measured RTO", r"4(?:6[12]|82)\s?s", ["README.md", "docs/06-measurements.md"]),
    ("measured RPO", r"2\.7\s*h", ["README.md", "docs/06-measurements.md"]),
    ("monthly cost", r"\$0\.53", ["README.md", "docs/02-cost-analysis.md", "JOURNEY.md"]),
    ("two-month cost", r"\$1\.06", ["README.md", "docs/02-cost-analysis.md"]),
    ("CNAME failover", r"CNAME", ["README.md", "docs/01-architecture.md"]),
    ("no registered domain", r"registered domain", ["README.md", "docs/01-architecture.md"]),
    ("test count", r"74 (?:unit )?tests", ["README.md", "JOURNEY.md"]),
    ("write-only IAM", r"write-only", ["README.md", "docs/03-security.md"]),
    ("cross-project skipped", r"cross-project", ["README.md", "MISSING.md", "docs/03-security.md"]),
    ("screen recording pending", r"screen recording", ["README.md", "MISSING.md"]),
    ("default SSH rule disabled", r"default-allow-ssh", ["README.md", "docs/03-security.md"]),
    ("default RDP rule disabled", r"default-allow-rdp", ["README.md", "docs/03-security.md"]),
    ("CRC32C", r"CRC32C", ["README.md", "docs/03-security.md"]),
    ("key supersession rule", r"supersed", ["docs/06-measurements.md", "src/functions/key-version-retirement/main.py"]),
    ("screenshot runbook", r"07-screenshot-runbook", ["README.md"]),
    ("Trivy in CI", r"[Tt]rivy", ["CI workflows"]),
]


def check_key_facts(text: dict[str, str]) -> None:
    rule("1. KEY FACTS — is every headline claim written down?")
    for label, pattern, where in KEY_FACTS:
        missing = [
            d
            for d in where
            if d in text and not re.search(pattern, text[d], re.IGNORECASE)
        ]
        absent_docs = [d for d in where if d not in text]
        if absent_docs:
            fail(f"{label}: document(s) not found: {', '.join(absent_docs)}")
        elif missing:
            fail(f"{label}: not mentioned in {', '.join(missing)}")
        else:
            ok(f"{label}")


# ---------------------------------------------------------------------------
# 2. Stale numbers
# ---------------------------------------------------------------------------

# A superseded figure is allowed to appear, but only in a passage that
# says it was superseded. These are the markers that make a historical
# mention honest rather than confusing.
CORRECTION_MARKERS = (
    "was",
    "were",
    "claimed",
    "estimate",
    "day 1",
    "day 6",
    "corrected",
    "used to",
    "old ",
    "superseded",
    "before",
    "earlier",
    "initially",
)

STALE = [
    (r"\$1\.40", "the Day-1 cost estimate, corrected to $0.53"),
    (r"1\.40/mo", "the Day-1 cost estimate, corrected to $0.53"),
    (r"\b47 tests\b", "an old test count"),
    (r"\b56 tests\b", "an old test count"),
    (r"\b67 tests\b", "an old test count"),
    (r"0\.7h \(42", "an RPO that was measured to be 2.7h"),
    (r"\b13 real bugs\b", "an old bug count"),
    (r"RPO 18h", "a Day-6 estimate, not the measurement"),
    (r"roles/dns\.resourceRecordsAdmin on that one zone",
     "a role that does not exist on GCP"),
    (r"\bPython 3\.12\b", "the VM runs Debian 12's Python 3.11.2"),
    (r"nginx 1\.27 \(reverse proxy\)", "the VM runs Debian 12's nginx 1.22.1"),
]

# How far from the stale figure a correction has to be for the mention to
# count as historical. Wide enough to cover a paragraph and the line
# before a table; narrow enough that an uncorrected number in a
# different section is still reported.
STALE_CONTEXT_CHARS = 600


def check_stale(text: dict[str, str]) -> None:
    rule("2. STALE NUMBERS — does a superseded figure only appear as history?")
    for pattern, why in STALE:
        offenders = []
        for name, body in text.items():
            for m in re.finditer(pattern, body):
                start = max(0, m.start() - STALE_CONTEXT_CHARS)
                window = body[start : m.end() + STALE_CONTEXT_CHARS].lower()
                if not any(marker in window for marker in CORRECTION_MARKERS):
                    offenders.append(f"{name} (line {body[: m.start()].count(chr(10)) + 1})")
        if offenders:
            fail(f"{pattern!r} appears without correction context: {', '.join(offenders)} — {why}")
        else:
            ok(f"{pattern!r} clean ({why})")


# ---------------------------------------------------------------------------
# 3. Links
# ---------------------------------------------------------------------------

LINK_RE = re.compile(r"\[([^\]]+)\]\(([^)\s]+)\)")
FENCE_RE = re.compile(r"^```.*?^```", re.DOTALL | re.MULTILINE)


def strip_code_blocks(body: str) -> str:
    """Remove fenced code blocks.

    Markdown examples inside a fence are illustrations, not live links —
    the runbook shows what a README's screenshot table should look like,
    with filenames that do not exist yet. Checking those would report
    the documentation as broken when it is a template.
    """
    return FENCE_RE.sub("", body)


def check_links(text: dict[str, str]) -> None:
    rule("3. LINKS — do all relative links resolve, and is everything linked?")
    broken = []
    for name, path in DOCS.items():
        body = strip_code_blocks(text[name])
        for m in LINK_RE.finditer(body):
            target = m.group(2)
            if target.startswith(("http://", "https://", "mailto:", "#")):
                continue
            target = target.split("#", 1)[0]
            if not target:
                continue
            if not (path.parent / target).exists():
                broken.append(f"{name} -> {target}")
    if broken:
        for b in broken:
            fail(f"broken link: {b}")
    else:
        ok(f"all relative links in {len(DOCS)} documents resolve")

    # Every document in the repository must be reachable from the README.
    # An unlinked document is one nobody will read.
    readme = text["README.md"]
    ignored_dirs = {".venv-test", ".git", "node_modules", ".terraform", ".pytest_cache", ".ruff_cache"}
    unlinked = []
    for path in sorted(ROOT.rglob("*.md")):
        if any(part in ignored_dirs for part in path.parts):
            continue
        rel = path.relative_to(ROOT).as_posix()
        if rel == "README.md":
            continue  # it is the README
        if "docs" in path.parts or path.name in {"JOURNEY.md", "MISSING.md", "gcp-checklist.md"}:
            if rel not in readme:
                unlinked.append(rel)
    if unlinked:
        for u in unlinked:
            fail(f"not linked from README.md: {u}")
    else:
        ok("every document in the repository is linked from README.md")


# ---------------------------------------------------------------------------
# 4. Cross-document number agreement
# ---------------------------------------------------------------------------

# (label, regex with one capture group, documents that must agree)
#
# The check compares the SET of values found in each document: the
# documents must find the same set. A single regex that is too greedy
# would flag every dollar amount in a cost table as a disagreement.
AGREEMENT = [
    ("monthly cost", r"\$0\.53(?:/mo| per month)?",
     ["README.md", "docs/02-cost-analysis.md", "JOURNEY.md"]),
    ("two-month cost", r"\$1\.06",
     ["README.md", "docs/02-cost-analysis.md"]),
    ("RTO seconds", r"\b(?:4(?:6[12]|82))s\b",
     ["README.md", "docs/06-measurements.md"]),
    ("test count", r"\b(7[0-9]) (?:unit )?tests\b",
     ["README.md", "JOURNEY.md", "MISSING.md"]),
    ("bug count", r"\b(3[0-9]) (?:real )?bugs\b",
     ["README.md", "JOURNEY.md", "MISSING.md", "docs/06-measurements.md"]),
]


def normalise(value: str) -> str:
    """Normalise a captured value so formatting does not look like disagreement.

    `$0.53` and `$0.53/mo` are the same number written two ways.
    """
    return value.rstrip("/mo").rstrip(" per month")


def check_agreement(text: dict[str, str]) -> None:
    rule("4. AGREEMENT — is the same number written the same way everywhere?")
    for label, pattern, where in AGREEMENT:
        seen: dict[str, set[str]] = {}
        for name in where:
            if name not in text:
                continue
            found = set()
            for m in re.finditer(pattern, text[name]):
                # The value is the first capture group if the pattern has
                # one, otherwise the whole match.
                raw = m.group(1) if m.re.groups else m.group(0)
                found.add(normalise(raw))
            seen[name] = found
        if not seen:
            fail(f"{label}: none of {', '.join(where)} is in the corpus")
            continue
        if not any(seen.values()):
            fail(f"{label}: not found in any of {', '.join(where)}")
            continue
        # The documents must find the SAME SET of values. A single
        # measurement has one value; three drill runs have three, and
        # all three documents must report all three.
        distinct = {frozenset(v) for v in seen.values()}
        if len(distinct) > 1:
            detail = "; ".join(f"{n}={sorted(v)}" for n, v in seen.items())
            fail(f"{label}: documents disagree — {detail}")
        else:
            values = sorted(next(iter(distinct)))
            ok(f"{label}: {values} in all of {', '.join(seen)}")


# ---------------------------------------------------------------------------
# 5. Structure
# ---------------------------------------------------------------------------


def check_structure(text: dict[str, str]) -> None:
    rule("5. STRUCTURE — does every document have a title?")
    for name in DOCS:
        body = text[name]
        first = body.splitlines()[0] if body.splitlines() else ""
        if not first.startswith("# "):
            fail(f"{name}: does not start with a level-1 heading")
        else:
            ok(f"{name}: {first[2:60]}")


def main() -> int:
    missing_files = [str(p.relative_to(ROOT)) for p in DOCS.values() if not p.exists()]
    if missing_files:
        for m in missing_files:
            fail(f"document missing: {m}")
        return 1

    text = {name: path.read_text(encoding="utf-8") for name, path in DOCS.items()}
    # The CI workflow is part of the contract, so it is audited too.
    # The project works in two layouts: standalone (the workflow sits
    # in the project's own .github/) and as a directory in a monorepo
    # (where the root-level workflow runs it). Look in both, and treat
    # the pair as one corpus entry.
    workflows = []
    for candidate in (
        ROOT / ".github/workflows/portfolio-ci.yml",
        ROOT / ".github/workflows/terraform.yml",
    ):
        if candidate.exists():
            workflows.append(candidate.read_text(encoding="utf-8"))
    if workflows:
        text["CI workflows"] = "\n".join(workflows)
    # The key-version retirement source is where the supersession rule
    # is implemented, so it is part of the contract too.
    retirement = ROOT / "src/functions/key-version-retirement/main.py"
    if retirement.exists():
        text[retirement.relative_to(ROOT).as_posix()] = retirement.read_text(encoding="utf-8")

    check_key_facts(text)
    check_stale(text)
    check_links(text)
    check_agreement(text)
    check_structure(text)

    print()
    print("=" * 72)
    if failures:
        print(f"DOCUMENTATION AUDIT: {len(failures)} FAILURE(S)")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("DOCUMENTATION AUDIT: CLEAN")
    return 0


if __name__ == "__main__":
    sys.exit(main())
