#!/usr/bin/env python3
"""
Verify that ai/brainstorming/brainstorm.json contains the same data as the
markdown originals + cross-review files. Run this AFTER build_brainstorm_json.py.

Three independent checks:
  1. Idea-row count per agent (markdown table vs JSON).
  2. Comment-row count per cross-review file (markdown vs JSON, by from_agent).
  3. Per-row content roundtrip: every (id, idea, category, justification,
     applies_to_phase) tuple in markdown must appear verbatim in the JSON.

Exits non-zero on any mismatch.
"""
from __future__ import annotations
import json
import re
import sys
from collections import Counter
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
BD = REPO / "ai" / "brainstorming"
JSON_PATH = BD / "brainstorm.json"

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

# Match the builder's column constraints exactly: id/category/phase forbid embedded
# pipes; idea/justification may contain pipes (e.g. inside `code` spans) and the
# regex backtracks to the last column boundary.
ORIG_ROW_RE = re.compile(r"^\|\s*(A[1-6]-\d+)\s*\|\s*(.+?)\s*\|\s*([^|]+?)\s*\|\s*(.+?)\s*\|\s*([^|]+?)\s*\|\s*$")
COMMENT_ROW_RE = re.compile(r"^\|\s*((?:A[1-6]|P)→A[1-6]-\d+)\s*\|\s*(.+?)\s*\|\s*([^|]+?)\s*\|\s*(.+?)\s*\|\s*([^|]+?)\s*\|\s*$")


def count_idea_rows(path: Path) -> int:
    n = 0
    for line in path.read_text().splitlines():
        if line.startswith("## Cross-review additions"):
            break
        if ORIG_ROW_RE.match(line):
            n += 1
    return n


def count_comment_rows(path: Path) -> int:
    return sum(1 for line in path.read_text().splitlines() if COMMENT_ROW_RE.match(line))


def parse_idea_tuples(path: Path) -> set[tuple]:
    out: set[tuple] = set()
    for line in path.read_text().splitlines():
        if line.startswith("## Cross-review additions"):
            break
        m = ORIG_ROW_RE.match(line)
        if m:
            out.add(tuple(g.strip() for g in m.groups()))
    return out


def parse_comment_tuples(path: Path) -> set[tuple]:
    out: set[tuple] = set()
    for line in path.read_text().splitlines():
        m = COMMENT_ROW_RE.match(line)
        if m:
            out.add(tuple(g.strip() for g in m.groups()))
    return out


def main() -> int:
    if not JSON_PATH.exists():
        print(f"FAIL: {JSON_PATH} not found — run build_brainstorm_json.py first", file=sys.stderr)
        return 2
    doc = json.loads(JSON_PATH.read_text())
    agents = {a["id"]: a for a in doc["agents"]}

    failures: list[str] = []

    # ---------- 1. Idea-row counts ----------
    for aid, fname in ORIGINALS.items():
        md_count = count_idea_rows(BD / fname)
        json_count = agents[aid]["idea_count"]
        json_actual = len(agents[aid]["ideas"])
        status = "OK" if md_count == json_count == json_actual else "FAIL"
        print(f"[1] {aid} ideas: markdown={md_count} json.idea_count={json_count} json.actual={json_actual} -> {status}")
        if status == "FAIL":
            failures.append(f"{aid} idea count mismatch")

    # ---------- 2. Comment-row counts by from_agent ----------
    # Collect all (comment_id, from_agent) pairs from JSON (de-duped because a
    # comment that resolves to N source ideas appears N times in the tree).
    json_comments_by_from: Counter = Counter()
    seen_ids: set[tuple[str, str]] = set()
    for agent in doc["agents"]:
        for idea in agent["ideas"]:
            for c in idea["comments"]:
                key = (c["from_agent"], c["comment_id"])
                if key in seen_ids:
                    continue
                seen_ids.add(key)
                json_comments_by_from[c["from_agent"]] += 1
        for c in agent["general_comments"]:
            key = (c["from_agent"], c["comment_id"])
            if key in seen_ids:
                continue
            seen_ids.add(key)
            json_comments_by_from[c["from_agent"]] += 1

    for src, fname in CR_FILES.items():
        md_count = count_comment_rows(BD / fname)
        # Map src key to from_agent value used in JSON
        from_agent = "PRIMARY" if src == "PRIMARY" else src
        json_count = json_comments_by_from[from_agent]
        status = "OK" if md_count == json_count else "FAIL"
        print(f"[2] {src} comments: markdown={md_count} json={json_count} -> {status}")
        if status == "FAIL":
            failures.append(f"{src} comment count mismatch ({md_count} vs {json_count})")

    # ---------- 3. Per-row content roundtrip ----------
    # 3a. Ideas: every markdown tuple must appear in JSON.
    for aid, fname in ORIGINALS.items():
        md_tuples = parse_idea_tuples(BD / fname)
        json_tuples = {(
            i["id"], i["idea"], i["category"], i["justification"], i["applies_to_phase"]
        ) for i in agents[aid]["ideas"]}
        missing = md_tuples - json_tuples
        extra = json_tuples - md_tuples
        if not missing and not extra:
            print(f"[3a] {aid} idea content: OK ({len(md_tuples)} rows match)")
        else:
            print(f"[3a] {aid} idea content: FAIL  missing_in_json={len(missing)} extra_in_json={len(extra)}")
            for x in list(missing)[:3]:
                print(f"     missing: {x[0]}", file=sys.stderr)
            failures.append(f"{aid} idea content mismatch")

    # 3b. Comments: every markdown comment tuple must appear at least once in JSON.
    for src, fname in CR_FILES.items():
        from_agent = "PRIMARY" if src == "PRIMARY" else src
        md_tuples = parse_comment_tuples(BD / fname)
        json_tuples: set[tuple] = set()
        for agent in doc["agents"]:
            for idea in agent["ideas"]:
                for c in idea["comments"]:
                    if c["from_agent"] != from_agent:
                        continue
                    json_tuples.add((c["comment_id"], c["idea"], c["category"], c["justification"], c["applies_to_phase"]))
            for c in agent["general_comments"]:
                if c["from_agent"] != from_agent:
                    continue
                json_tuples.add((c["comment_id"], c["idea"], c["category"], c["justification"], c["applies_to_phase"]))
        missing = md_tuples - json_tuples
        if not missing:
            print(f"[3b] {src} comment content: OK ({len(md_tuples)} unique rows present in JSON)")
        else:
            print(f"[3b] {src} comment content: FAIL  missing_in_json={len(missing)}")
            for x in list(missing)[:3]:
                print(f"     missing: {x[0]}", file=sys.stderr)
            failures.append(f"{src} comment content mismatch")

    print("")
    if failures:
        print(f"VERIFY FAILED: {len(failures)} mismatch(es)", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        return 1
    print("VERIFY OK — markdown corpus and brainstorm.json agree on every row.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
