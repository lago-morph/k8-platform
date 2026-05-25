#!/usr/bin/env python3
"""
Verify that ai/brainstorming/brainstorm.md is a STRICT SUPERSET of the
information in the original source files (the six A{N}-*.md and the seven
cross-review-from-*.md files), to within markdown-cell escaping.

For every (id, idea, category, justification, applies_to_phase) tuple
present in the source markdown, all five values must appear in the
rendered file.

Two passes:
  PASS A (substring presence): each value must appear at least once in
    the rendered markdown (after un-escaping cell-safe characters).
  PASS B (co-location): for every idea_id / comment_id, all five fields
    of that row must appear within a single contiguous line of the
    rendered markdown (since each row is rendered as one line).

Exits non-zero on any missing tuple. Prints a per-tuple diagnostic.
"""
from __future__ import annotations
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
BD = REPO / "ai" / "brainstorming"
RENDERED = BD / "brainstorm.md"

ORIGINALS = {
    "A1": "A1-debug-tools-max-capability.md",
    "A2": "A2-integration-e2e-tests-max-capability.md",
    "A3": "A3-test-gaps-prior-constraints.md",
    "A4": "A4-debug-tool-gaps-prior-constraints.md",
    "A5": "A5-orchestration-post-actions.md",
    "A6": "A6-removal-refactor.md",
}
CR_FILES = {a: f"cross-review-from-{a}.md" for a in ORIGINALS}
CR_FILES["PRIMARY"] = "cross-review-from-primary.md"

# Same column constraints as the verifier — id/category/phase forbid '|',
# idea/justification allow it (via backtracking).
ORIG_ROW_RE = re.compile(r"^\|\s*(A[1-6]-\d+)\s*\|\s*(.+?)\s*\|\s*([^|]+?)\s*\|\s*(.+?)\s*\|\s*([^|]+?)\s*\|\s*$")
COMMENT_ROW_RE = re.compile(r"^\|\s*((?:A[1-6]|P)→A[1-6]-\d+)\s*\|\s*(.+?)\s*\|\s*([^|]+?)\s*\|\s*(.+?)\s*\|\s*([^|]+?)\s*\|\s*$")


def un_md_cell(text: str) -> str:
    """Reverse the cell-escaping render_markdown.py applies."""
    return text.replace("&#124;", "|").replace("<br>", " ")


def collect_idea_tuples() -> list[tuple]:
    out = []
    for aid, fname in ORIGINALS.items():
        for line in (BD / fname).read_text().splitlines():
            if line.startswith("## Cross-review additions"):
                break
            m = ORIG_ROW_RE.match(line)
            if m:
                # (kind, id, idea, category, justification, phase)
                out.append(("idea", *[g.strip() for g in m.groups()]))
    return out


def collect_comment_tuples() -> list[tuple]:
    out = []
    for src, fname in CR_FILES.items():
        for line in (BD / fname).read_text().splitlines():
            m = COMMENT_ROW_RE.match(line)
            if m:
                out.append(("comment", *[g.strip() for g in m.groups()]))
    return out


def main() -> int:
    if not RENDERED.exists():
        print(f"FAIL: {RENDERED} missing — run render_markdown.py", file=sys.stderr)
        return 2

    raw = RENDERED.read_text()
    flat = un_md_cell(raw)
    lines_flat = [un_md_cell(l) for l in raw.splitlines()]

    sources = collect_idea_tuples() + collect_comment_tuples()
    missing_subA: list[tuple] = []
    missing_subB: list[tuple] = []

    for tpl in sources:
        kind, rid, idea, cat, just, phase = tpl

        # PASS A — substring presence anywhere in the file.
        for label, val in (("id", rid), ("idea", idea), ("cat", cat),
                            ("just", just), ("phase", phase)):
            if val not in flat:
                missing_subA.append((kind, rid, label, val))

        # PASS B — co-location on a single rendered line. The row's
        # durable id anchors the search; all four other fields must appear
        # somewhere on the SAME line as that id.
        anchor_lines = [ln for ln in lines_flat if rid in ln]
        if not anchor_lines:
            missing_subB.append((kind, rid, "anchor-line", rid))
            continue
        for label, val in (("idea", idea), ("cat", cat),
                            ("just", just), ("phase", phase)):
            if not any(val in ln for ln in anchor_lines):
                missing_subB.append((kind, rid, label, val))

    print(f"sources: {len(sources)} tuples ({sum(1 for s in sources if s[0]=='idea')} ideas + {sum(1 for s in sources if s[0]=='comment')} comments)")
    print(f"PASS A (substring presence anywhere): {len(missing_subA)} missing")
    print(f"PASS B (co-located on one rendered line): {len(missing_subB)} missing")

    if missing_subA:
        print("\nPASS A failures (up to 20):", file=sys.stderr)
        for m in missing_subA[:20]:
            print(f"  {m[0]} {m[1]}: {m[2]} value not in rendered: {m[3][:120]!r}", file=sys.stderr)

    if missing_subB:
        print("\nPASS B failures (up to 20):", file=sys.stderr)
        for m in missing_subB[:20]:
            print(f"  {m[0]} {m[1]}: {m[2]} not co-located on the row's anchor line: {m[3][:120]!r}", file=sys.stderr)

    if missing_subA or missing_subB:
        print("\nSTRICT-SUPERSET CHECK FAILED.", file=sys.stderr)
        return 1
    print("\nSTRICT-SUPERSET CHECK PASSED — every source tuple is present in the rendered file and co-located on its anchor row.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
