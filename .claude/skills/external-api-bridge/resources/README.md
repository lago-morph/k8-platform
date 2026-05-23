# `resources/<endpoint>.json` Schema

Every `ext-{service}` child skill commits one JSON file per endpoint
into its own `resources/` directory (i.e.
`.claude/skills/ext-{service}/resources/<endpoint>.json`). This file
defines the strict shape those JSON files must follow.

Authority: the canonical design at `ai/specs/ext-github-design.md`
§6. If anything below disagrees with that spec, the spec wins —
file a fix to this README.

---

## Top-level shape

```json
{
  "endpoint_ref": "<jentic catalog identifier, optional>",
  "recorded_at": "<ISO-8601 timestamp>",
  "verified": true,
  "request": {
    "method": "POST | GET | PUT | PATCH | DELETE",
    "url_template": "https://api.example.com/path/{with}/{placeholders}",
    "headers": { "Content-Type": "application/json", "Accept": "..." },
    "query":   { "<key>": "<recorded value>" },
    "query_inputs_schema": {
      "<key>": { "required": true, "values": ["..."], "default": "..." }
    },
    "body":    { "<key>": "<recorded value>" },
    "body_inputs_schema": {
      "<key>": { "required": true, "values": ["..."], "default": "..." }
    }
  },
  "response": {
    "status": 204
  }
}
```

### Field-by-field

| Field | Required | Notes |
|---|---|---|
| `endpoint_ref` | optional | Jentic's stable identifier from the catalog search (e.g. `op_2acb005c9f3704ad`). In practice jentic does return these, but the field is optional so a future catalog that doesn't can still produce conformant recordings. |
| `recorded_at` | required | ISO-8601 timestamp of the successful live-fire probe. Audit only. There is no drift detection — see §4 of the canonical spec. |
| `verified` | required | `true` if the recording was captured from a successful live-fire probe. `false` only when the user vetoed the live-fire during test-plan negotiation and explicitly chose to ship with a documentation-derived recording. When `false`, the child SKILL.md §6 must surface a warning on every invocation. |
| `request.method` | required | HTTP verb. |
| `request.url_template` | required | Full URL with `{placeholders}` for path parameters. |
| `request.headers` | required | Literal headers as recorded. Auth headers are NOT recorded — jentic supplies them at call time. Typically only `Content-Type` and `Accept`. |
| `request.query` | optional | Concrete recorded query-string values. Omit for endpoints with no query string. |
| `request.query_inputs_schema` | optional | Per-key descriptor for `query` keys that are call-time inputs. See §"`*_inputs_schema` per-key shape" below. Keys in `query` not listed here are fixed and reused as-is. |
| `request.body` | optional | Concrete recorded body. Omit for GET/HEAD/DELETE typically. |
| `request.body_inputs_schema` | optional | Per-key descriptor for `body` keys that are call-time inputs. Same shape as `query_inputs_schema`. |
| `response.status` | required | Single status code observed during the probe. No response body schema — drift detection was deliberately dropped. |

POST/PUT/PATCH endpoints typically use `body` + `body_inputs_schema`.
GET endpoints typically use `query` + `query_inputs_schema`. Either
pair may be omitted when the method doesn't carry that section.

---

## `*_inputs_schema` per-key shape

Each entry in `body_inputs_schema` or `query_inputs_schema` uses
this fixed shape:

| Key | Type | Required? | Meaning |
|---|---|---|---|
| `required` | bool | yes | Whether the input must be supplied at call time. |
| `values` | array of literals | no | Enumerated allowed values. Omit when the value space is unbounded (e.g. branch names, refs). |
| `default` | literal | no | Value to substitute when the key is absent at call time. Only meaningful when `required: false`. |

The three common patterns:

**Enumerated:**

```json
"action": { "required": true, "values": ["plan", "apply", "verify", "apply-and-verify", "destroy"] }
```

**Free-form (unbounded values):**

```json
"ref": { "required": true }
```

**Defaulted (optional with a fallback):**

```json
"per_page": { "required": false, "default": 30 }
```

A key listed in `body` or `query` but **not** in the corresponding
`_inputs_schema` is treated as **fixed**: the agent reuses the
recorded value as-is on every call. This is how mechanical reuse
stays safe — only declared inputs are templated.

---

## Worked example: `workflow_dispatch`

This is the canonical example. Once PR2 (`ext-github`) lands, it
will live at
`.claude/skills/ext-github/resources/workflow_dispatch.json`. Until
then, treat this as the reference shape new children should match.

```json
{
  "endpoint_ref": "op_2acb005c9f3704ad",
  "recorded_at": "2026-05-23T00:00:00Z",
  "verified": false,
  "request": {
    "method": "POST",
    "url_template": "https://api.github.com/repos/{owner}/{repo}/actions/workflows/{workflow_id}/dispatches",
    "headers": {
      "Accept": "application/vnd.github+json",
      "Content-Type": "application/json",
      "X-GitHub-Api-Version": "2022-11-28"
    },
    "body": {
      "ref": "branch-name",
      "inputs": {
        "phase": "base",
        "action": "plan"
      }
    },
    "body_inputs_schema": {
      "ref":             { "required": true },
      "inputs.phase":    { "required": true, "values": ["base", "management", "test"] },
      "inputs.action":   { "required": true, "values": ["plan", "apply", "verify", "apply-and-verify", "destroy", "test-unit", "test-e2e"] }
    }
  },
  "response": {
    "status": 204
  }
}
```

Note `verified: false` here — this example is documentation-derived
and is not a substitute for the real recording that PR2 will produce
from a live-fire probe. The `body_inputs_schema` uses dotted-path
keys (`inputs.phase`, `inputs.action`) to address nested fields; the
flat-key form (`phase`, `action`) is fine when the body is one level
deep.

---

## Pre-commit check

A `<endpoint>.json` file is conformant when:

- All required keys above are present.
- `verified` is either `true` (live-fired) or `false` with the
  warning surfaced in the child SKILL.md §6.
- `recorded_at` parses as a valid ISO-8601 timestamp.
- Every key in `body_inputs_schema` exists in `body` (and same for
  query).
- `response.status` is an integer 1xx–5xx.
- The pre-commit checklist in `TEMPLATE.md` is fully ticked for
  this child.
