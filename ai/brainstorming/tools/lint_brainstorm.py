#!/usr/bin/env python3
"""
Validate ai/brainstorming/brainstorm.json against brainstorm.schema.json.

Uses the `jsonschema` package if installed (preferred — full Draft 2020-12
validation). Falls back to a structural check that enforces the required
shape and pattern constraints.
"""
from __future__ import annotations
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
TOOLS = REPO / "ai" / "brainstorming" / "tools"
JSON_PATH = REPO / "ai" / "brainstorming" / "brainstorm.json"
SCHEMA_PATH = TOOLS / "brainstorm.schema.json"


def try_jsonschema(doc, schema) -> tuple[bool, str]:
    try:
        import jsonschema  # type: ignore
    except ImportError:
        return False, "jsonschema not installed"
    try:
        jsonschema.validate(instance=doc, schema=schema)
    except jsonschema.ValidationError as e:
        return False, f"schema violation at {list(e.absolute_path)}: {e.message}"
    return True, "jsonschema Draft 2020-12 validation passed"


def fallback_check(doc, schema) -> tuple[bool, str]:
    """Structural sanity check covering the most important invariants."""
    errors: list[str] = []
    if not isinstance(doc, dict):
        return False, "top-level must be object"
    for k in ("metadata", "agents"):
        if k not in doc:
            errors.append(f"missing top-level key: {k}")
    meta = doc.get("metadata", {})
    for k in ("session", "date", "branch", "totals"):
        if k not in meta:
            errors.append(f"metadata missing: {k}")
    if "date" in meta and not re.match(r"^\d{4}-\d{2}-\d{2}$", meta["date"]):
        errors.append(f"metadata.date not YYYY-MM-DD: {meta['date']}")
    totals = meta.get("totals", {})
    for k in ("agents", "ideas", "comments", "comment_associations", "general_comments"):
        if k not in totals:
            errors.append(f"metadata.totals missing: {k}")
        elif not isinstance(totals[k], int):
            errors.append(f"metadata.totals.{k} not int")

    agents = doc.get("agents", [])
    if not isinstance(agents, list) or not agents:
        errors.append("agents must be non-empty array")
    agent_id_re = re.compile(r"^A[1-6]$")
    idea_id_re = re.compile(r"^A[1-6]-\d+$")
    phase_re = re.compile(r"^(?:\d\+|\d[–—-]\d)$")
    from_re = re.compile(r"^(A[1-6]|PRIMARY)$")
    seen_idea_ids: set[str] = set()
    for ai, a in enumerate(agents):
        prefix = f"agents[{ai}]"
        for k in ("id", "short_mandate", "long_mandate", "source_file", "ideas", "general_comments"):
            if k not in a:
                errors.append(f"{prefix} missing: {k}")
        if "id" in a and not agent_id_re.match(a["id"]):
            errors.append(f"{prefix}.id invalid: {a['id']}")
        for ii, idea in enumerate(a.get("ideas", [])):
            ip = f"{prefix}.ideas[{ii}]"
            for k in ("id", "idea", "category", "justification", "applies_to_phase", "comments"):
                if k not in idea:
                    errors.append(f"{ip} missing: {k}")
            if "id" in idea:
                if not idea_id_re.match(idea["id"]):
                    errors.append(f"{ip}.id invalid: {idea['id']}")
                if idea["id"] in seen_idea_ids:
                    errors.append(f"{ip}.id duplicate: {idea['id']}")
                seen_idea_ids.add(idea["id"])
            if "applies_to_phase" in idea and not phase_re.match(idea["applies_to_phase"]):
                errors.append(f"{ip}.applies_to_phase non-canonical: {idea['applies_to_phase']}")
            for ci, c in enumerate(idea.get("comments", [])):
                cp = f"{ip}.comments[{ci}]"
                for k in ("comment_id", "from_agent", "to_agent", "idea", "category",
                         "justification", "applies_to_phase", "references"):
                    if k not in c:
                        errors.append(f"{cp} missing: {k}")
                if "from_agent" in c and not from_re.match(c["from_agent"]):
                    errors.append(f"{cp}.from_agent invalid: {c['from_agent']}")
                if "to_agent" in c and not agent_id_re.match(c["to_agent"]):
                    errors.append(f"{cp}.to_agent invalid: {c['to_agent']}")
                if "references" in c and not isinstance(c["references"], list):
                    errors.append(f"{cp}.references not list")
                for ri, ref in enumerate(c.get("references", [])):
                    if not idea_id_re.match(ref):
                        errors.append(f"{cp}.references[{ri}] invalid: {ref}")
        for gi, c in enumerate(a.get("general_comments", [])):
            cp = f"{prefix}.general_comments[{gi}]"
            for k in ("comment_id", "from_agent", "to_agent", "idea", "category",
                     "justification", "applies_to_phase", "references"):
                if k not in c:
                    errors.append(f"{cp} missing: {k}")
            if "references" in c and c["references"]:
                errors.append(f"{cp}.references should be empty for a general comment (got {c['references']})")
    if errors:
        return False, "\n  ".join([f"{len(errors)} structural error(s):"] + errors[:25])
    return True, f"structural fallback passed ({len(agents)} agents, {len(seen_idea_ids)} ideas)"


def main() -> int:
    if not SCHEMA_PATH.exists():
        print(f"FAIL: schema missing at {SCHEMA_PATH}", file=sys.stderr)
        return 2
    if not JSON_PATH.exists():
        print(f"FAIL: data missing at {JSON_PATH} — run build_brainstorm_json.py", file=sys.stderr)
        return 2
    schema = json.loads(SCHEMA_PATH.read_text())
    doc = json.loads(JSON_PATH.read_text())

    js_ok, js_msg = try_jsonschema(doc, schema)
    fb_ok, fb_msg = fallback_check(doc, schema)

    print(f"[schema]    {'OK' if js_ok else 'SKIP/FAIL'}: {js_msg}")
    print(f"[structure] {'OK' if fb_ok else 'FAIL'}: {fb_msg}")

    # The linter passes if EITHER the formal schema check passes OR the structural
    # fallback passes (since jsonschema may not be installed in every sandbox).
    if js_ok or fb_ok:
        # But if jsonschema IS installed and reports a failure, treat as fatal.
        if not js_ok and js_msg != "jsonschema not installed":
            return 1
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
