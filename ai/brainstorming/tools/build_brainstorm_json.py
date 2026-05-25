#!/usr/bin/env python3
"""
Build ai/brainstorming/brainstorm.json from the markdown originals + cross-reviews.

Lossless port. No re-summarization. Every cell in every table appears verbatim
in the JSON output. Comments are attached to source ideas by parsing the
inline `A{N}-NNN` references in the comment text.

Run from repo root:  python3 ai/brainstorming/tools/build_brainstorm_json.py
"""
from __future__ import annotations
import json
import re
import sys
from pathlib import Path
from typing import Iterable

REPO = Path(__file__).resolve().parents[3]
BD = REPO / "ai" / "brainstorming"
OUT = BD / "brainstorm.json"

ORIGINALS = {
    "A1": "A1-debug-tools-max-capability.md",
    "A2": "A2-integration-e2e-tests-max-capability.md",
    "A3": "A3-test-gaps-prior-constraints.md",
    "A4": "A4-debug-tool-gaps-prior-constraints.md",
    "A5": "A5-orchestration-post-actions.md",
    "A6": "A6-removal-refactor.md",
}

# 3-word handles authored to satisfy the schema. NOT taken from prose —
# these are deliberate short labels.
SHORT_MANDATES = {
    "A1": "Max-capability debug tools",
    "A2": "Max-capability integration tests",
    "A3": "Test gap mining",
    "A4": "Debug gap mining",
    "A5": "Orchestration parallelism opportunities",
    "A6": "Cruft removal targets",
}

CR_FILES = {a: f"cross-review-from-{a}.md" for a in ORIGINALS}
CR_FILES["PRIMARY"] = "cross-review-from-primary.md"

# Header / mandate parsing
MANDATE_RE = re.compile(r"^-\s*Mandate:\s*(.+?)\s*$", re.MULTILINE)

# Table row parsing — strict 5-column form.
TABLE_ROW_RE = re.compile(r"^\|\s*(?P<id>[^|]+?)\s*\|\s*(?P<idea>.+?)\s*\|\s*(?P<cat>[^|]+?)\s*\|\s*(?P<just>.+?)\s*\|\s*(?P<phase>[^|]+?)\s*\|\s*$")
# Skip header + separator rows ("| ID | ... |" and "|---|---|...").
HEADER_ID_TOKENS = {"ID", "id"}

ORIG_ID_RE = re.compile(r"^A[1-6]-\d+$")
COMMENT_ID_RE = re.compile(r"^(A[1-6]|P)→A[1-6]-\d+$")

# In comment text, find references to source-idea IDs (A1-001, A1-1, A1-019).
# Capture both 2- and 3-digit forms; some cross-reviews wrote `A1-1` not `A1-001`.
SOURCE_REF_RE = re.compile(r"\bA([1-6])-(\d{1,3})\b")
# Capture Bug N + PR #N references for external_refs.
EXTERNAL_REF_RE = re.compile(r"(?:Bug\s+\d+|PR\s*#\s*\d+)", re.IGNORECASE)

# Cross-review section header for a specific target file.
SECTION_HEADER_RE = re.compile(r"^##\s+For\s+(?P<file>A[1-6]-[A-Za-z0-9_.-]+\.md)\s*$", re.MULTILINE)


def split_at_cross_review(text: str) -> str:
    """Return text up to (but excluding) the '## Cross-review additions' heading."""
    idx = text.find("## Cross-review additions")
    return text if idx < 0 else text[:idx]


def parse_table_rows(block: str) -> list[dict]:
    """Yield dicts for every table data row in the block."""
    rows: list[dict] = []
    for line in block.splitlines():
        if not line.startswith("|"):
            continue
        # Skip separator rows.
        if re.match(r"^\|\s*[-:]+\s*\|", line):
            continue
        m = TABLE_ROW_RE.match(line)
        if not m:
            continue
        if m.group("id").strip() in HEADER_ID_TOKENS:
            continue
        rows.append({
            "id": m.group("id").strip(),
            "idea": m.group("idea").strip(),
            "category": m.group("cat").strip(),
            "justification": m.group("just").strip(),
            "applies_to_phase": m.group("phase").strip(),
        })
    return rows


def normalize_phase(p: str) -> str:
    """Coerce phase strings like '0+', '1+', '6+'. Leave unchanged if not matching."""
    m = re.match(r"^(\d)\s*\+?$", p)
    return f"{m.group(1)}+" if m else p


def normalize_ref(raw_num: str) -> str:
    """Some refs are A1-1, others A1-001 — canonicalize numeric part by trying both
    and letting the resolver decide. Return both candidates."""
    # We'll resolve against the actual idea set, so just return the literal here.
    return raw_num


def parse_original(agent_id: str, path: Path) -> dict:
    text = path.read_text()
    mandate_m = MANDATE_RE.search(text)
    long_mandate = mandate_m.group(1).strip() if mandate_m else ""
    # Only look at the table BEFORE the cross-review additions section.
    head_block = split_at_cross_review(text)
    raw_rows = parse_table_rows(head_block)
    # Filter to rows whose id matches A{N}-NNN. (Header tokens were already filtered.)
    ideas = []
    for r in raw_rows:
        if not ORIG_ID_RE.match(r["id"]):
            continue
        ideas.append({
            "id": r["id"],
            "idea": r["idea"],
            "category": r["category"],
            "justification": r["justification"],
            "applies_to_phase": normalize_phase(r["applies_to_phase"]),
            "comments": [],
        })
    return {
        "id": agent_id,
        "short_mandate": SHORT_MANDATES[agent_id],
        "long_mandate": long_mandate,
        "source_file": str(path.relative_to(REPO)),
        "idea_count": len(ideas),
        "ideas": ideas,
        "general_comments": [],
    }


def split_cross_review_sections(text: str) -> list[tuple[str, str]]:
    """Return list of (target_filename, body) sections."""
    matches = list(SECTION_HEADER_RE.finditer(text))
    sections = []
    for i, m in enumerate(matches):
        start = m.end()
        end = matches[i + 1].start() if i + 1 < len(matches) else len(text)
        sections.append((m.group("file"), text[start:end]))
    return sections


def file_to_agent(filename: str) -> str:
    return filename[:2]  # 'A1-...' -> 'A1'


def extract_references(idea_text: str, target_agent: str) -> tuple[list[str], list[str]]:
    """Find A{target}-NNN refs in idea_text. Also find external refs (Bug N, PR #N)."""
    refs: list[str] = []
    seen: set[str] = set()
    for m in SOURCE_REF_RE.finditer(idea_text):
        agent_num, num = m.group(1), m.group(2)
        if f"A{agent_num}" != target_agent:
            continue
        # Canonical: keep original numeric form; we'll resolve in caller.
        key = f"A{agent_num}-{num}"
        if key not in seen:
            seen.add(key)
            refs.append(key)
    external = list({m.group(0) for m in EXTERNAL_REF_RE.finditer(idea_text)})
    return refs, external


def resolve_ref(ref: str, idea_index: dict[str, dict]) -> str | None:
    """Try literal then zero-padded then unpadded match against the agent's idea index."""
    if ref in idea_index:
        return ref
    m = re.match(r"^(A[1-6])-(\d+)$", ref)
    if not m:
        return None
    base, num = m.group(1), m.group(2)
    # Try a few common pad widths.
    for width in (3, 2, 1):
        candidate = f"{base}-{int(num):0{width}d}"
        if candidate in idea_index:
            return candidate
    return None


def parse_cross_review(path: Path, from_agent: str, agents: dict[str, dict]) -> tuple[int, int, int]:
    """Parse one cross-review file; attach comments to agents in-place.

    Returns (comment_rows, associations, general_comments_added).
    """
    text = path.read_text()
    sections = split_cross_review_sections(text)
    comment_rows = 0
    associations = 0
    generals = 0
    for target_file, body in sections:
        to_agent = file_to_agent(target_file)
        if to_agent not in agents:
            continue
        idea_index = {idea["id"]: idea for idea in agents[to_agent]["ideas"]}
        for r in parse_table_rows(body):
            if not COMMENT_ID_RE.match(r["id"]):
                continue
            comment_rows += 1
            refs_raw, externals = extract_references(r["idea"], to_agent)
            resolved: list[str] = []
            for raw in refs_raw:
                actual = resolve_ref(raw, idea_index)
                if actual and actual not in resolved:
                    resolved.append(actual)
            base_comment = {
                "comment_id": r["id"],
                "from_agent": from_agent,
                "to_agent": to_agent,
                "idea": r["idea"],
                "category": r["category"],
                "justification": r["justification"],
                "applies_to_phase": normalize_phase(r["applies_to_phase"]),
                "references": resolved,
                "external_refs": externals,
            }
            if resolved:
                for target_id in resolved:
                    # Each association is a copy to keep the JSON tree-shaped.
                    idea_index[target_id]["comments"].append(base_comment)
                    associations += 1
            else:
                agents[to_agent]["general_comments"].append(base_comment)
                generals += 1
    return comment_rows, associations, generals


def build() -> dict:
    agents = {}
    for aid, fname in ORIGINALS.items():
        agents[aid] = parse_original(aid, BD / fname)

    total_comment_rows = 0
    total_assoc = 0
    total_general = 0
    for src_agent, fname in CR_FILES.items():
        path = BD / fname
        if not path.exists():
            print(f"WARN: missing {path}", file=sys.stderr)
            continue
        rows, assoc, gen = parse_cross_review(path, src_agent, agents)
        total_comment_rows += rows
        total_assoc += assoc
        total_general += gen

    doc = {
        "metadata": {
            "session": "2026-05-25 six-agent brainstorm fanout (A1-A6 + cross-review + primary pass)",
            "date": "2026-05-25",
            "branch": "claude/determined-pasteur-53fAN",
            "pr": 73,
            "totals": {
                "agents": len(agents),
                "ideas": sum(a["idea_count"] for a in agents.values()),
                "comments": total_comment_rows,
                "comment_associations": total_assoc,
                "general_comments": total_general,
            },
        },
        "agents": [agents[k] for k in sorted(agents.keys())],
    }
    return doc


def main() -> int:
    doc = build()
    OUT.write_text(json.dumps(doc, indent=2, ensure_ascii=False) + "\n")
    t = doc["metadata"]["totals"]
    print(f"wrote {OUT.relative_to(REPO)}")
    print(f"  agents={t['agents']} ideas={t['ideas']} comments={t['comments']}")
    print(f"  comment_associations={t['comment_associations']} general_comments={t['general_comments']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
