#!/usr/bin/env python3
"""
Render ai/brainstorming/brainstorm.json -> ai/brainstorming/brainstorm.md.

One section per agent. Within each section, a pipe table with one ROW per
idea. The row carries:
  - durable ID
  - phase(s) the idea applies to
  - the idea text + its category + its justification (all source fields
    embedded so the rendered file is a strict superset of the originals)
  - a bulleted list of comments about the idea, bullet-prefixed by the
    commenter's agent id (A1..A6 or PRIMARY)

After the per-agent tables, a "General comments" table per agent captures
cross-review rows that didn't reference a specific source idea by id.

This script reads ONLY from `brainstorm.json` (via the stdlib `json`
module) — never re-parses the original markdown.
"""
from __future__ import annotations
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
JSON_PATH = REPO / "ai" / "brainstorming" / "brainstorm.json"
OUT = REPO / "ai" / "brainstorming" / "brainstorm.md"


def md_cell(text: str) -> str:
    """Escape a string for inclusion in a markdown pipe-table cell.

    Pipes inside the cell would break the column count, so they are
    HTML-encoded. Newlines inside a cell become <br>. Backslashes and
    other markdown characters are left intact (so backticks etc. render).
    """
    if text is None:
        return ""
    out = text.replace("|", "&#124;")
    out = out.replace("\n", "<br>")
    return out


def commenter_label(c: dict) -> str:
    """`A2` or `PRIMARY` — the source agent."""
    return c["from_agent"]


def render_comment_bullet(c: dict) -> str:
    """One bullet line within a Comments cell.

    Carries: durable comment_id, commenter agent, category, phase,
    idea text, and justification. All five comment fields are included so
    the rendered output is a strict superset of the source rows.
    """
    label = commenter_label(c)
    parts = [
        f"**{label}** ({c['comment_id']} · _{c['category']}_ · phase {c['applies_to_phase']}):",
        md_cell(c["idea"]),
        f"— _{md_cell(c['justification'])}_",
    ]
    return "• " + " ".join(parts)


def render_idea_row(idea: dict) -> str:
    idea_cell_lines = [
        md_cell(idea["idea"]),
        f"<sub>_{md_cell(idea['category'])}_ · {md_cell(idea['justification'])}_</sub>",
    ]
    idea_cell = "<br><br>".join(idea_cell_lines)

    if idea["comments"]:
        # De-duplicate comments that appear under multiple ideas (a comment
        # referencing multiple source IDs lives in each idea's list).
        seen: set[str] = set()
        bullets = []
        for c in idea["comments"]:
            key = (c["from_agent"], c["comment_id"])
            if key in seen:
                continue
            seen.add(key)
            bullets.append(render_comment_bullet(c))
        # Stable sort: commenter agent ascending, then comment_id.
        bullets.sort()
        comment_cell = "<br>".join(bullets)
    else:
        comment_cell = "_(no comments)_"

    return f"| `{idea['id']}` | {idea['applies_to_phase']} | {idea_cell} | {comment_cell} |"


def render_general_comments(agent: dict) -> str:
    if not agent["general_comments"]:
        return ""
    out = [
        f"### {agent['id']} — General comments (no source-ID anchor)",
        "",
        "Cross-review rows targeted at this agent but without an explicit `A{N}-NNN` reference in the comment text; preserved verbatim.",
        "",
        "| Comment ID | From | Phase | Comment | Category & justification |",
        "|---|---|---|---|---|",
    ]
    rows = []
    for c in agent["general_comments"]:
        rows.append(
            f"| `{c['comment_id']}` | {c['from_agent']} | {c['applies_to_phase']} | "
            f"{md_cell(c['idea'])} | _{md_cell(c['category'])}_ — {md_cell(c['justification'])} |"
        )
    rows.sort()
    out.extend(rows)
    out.append("")
    return "\n".join(out)


def render_agent(agent: dict) -> str:
    out = [
        f"## {agent['id']} — {agent['short_mandate']}",
        "",
        f"> **Mandate.** {agent['long_mandate']}",
        "",
        f"_Source file: [`{agent['source_file']}`](../../{agent['source_file']})_",
        "",
        f"_Idea count: {agent['idea_count']}_",
        "",
        "| ID | Phase | Idea (with category and justification) | Comments (bulleted by commenter) |",
        "|---|---|---|---|",
    ]
    for idea in agent["ideas"]:
        out.append(render_idea_row(idea))
    out.append("")
    gen = render_general_comments(agent)
    if gen:
        out.append(gen)
    return "\n".join(out)


def render_metadata(doc: dict) -> str:
    m = doc["metadata"]
    t = m["totals"]
    out = [
        "# Brainstorm corpus — rendered view",
        "",
        f"_Generated from `ai/brainstorming/brainstorm.json` by `ai/brainstorming/tools/render_markdown.py`. This file is a derived view — every value here is also in the source markdown (A1-A6 + cross-review-from-\\*) and the JSON. Do not edit by hand; rebuild via `python3 ai/brainstorming/tools/render_markdown.py`._",
        "",
        "| Field | Value |",
        "|---|---|",
        f"| Session | {m['session']} |",
        f"| Date | {m['date']} |",
        f"| Branch | `{m['branch']}` |",
        f"| PR | #{m.get('pr', '—')} |",
        f"| Agents | {t['agents']} |",
        f"| Ideas | {t['ideas']} |",
        f"| Comments (distinct rows) | {t['comments']} |",
        f"| Comment ↔ idea associations | {t['comment_associations']} |",
        f"| General (unanchored) comments | {t['general_comments']} |",
        "",
        "## Table of contents",
        "",
    ]
    for a in doc["agents"]:
        out.append(f"- [{a['id']} — {a['short_mandate']}](#{a['id'].lower()}--{a['short_mandate'].lower().replace(' ', '-').replace('+', '')})")
    out.append("")
    return "\n".join(out)


def main() -> int:
    if not JSON_PATH.exists():
        print(f"FAIL: {JSON_PATH} missing — run build_brainstorm_json.py", file=sys.stderr)
        return 2
    doc = json.loads(JSON_PATH.read_text())
    chunks = [render_metadata(doc)]
    for agent in doc["agents"]:
        chunks.append(render_agent(agent))
    OUT.write_text("\n".join(chunks) + "\n")
    print(f"wrote {OUT.relative_to(REPO)}  ({OUT.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
