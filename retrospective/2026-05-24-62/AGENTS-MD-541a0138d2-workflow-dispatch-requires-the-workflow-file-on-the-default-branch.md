# agent instruction

**§6.X — `workflow_dispatch` requires the workflow file to exist on the default branch.** GitHub will accept `workflow_dispatch` against non-default refs ONLY if the workflow's `.yml` is already on the default branch. Dispatching from a feature branch where the workflow was newly authored returns HTTP 404 / `Not Found`. To bootstrap a new dispatch workflow, open a small workflow-only PR and merge it first; THEN dispatch from feature branches.

*Grounded in: PR #60's `phase-2-diagnose.yml` couldn't be dispatched from its feature branch until merged — surfaced as a confusing chicken-and-egg moment mid-session.*

# justification

The first time an agent hits this it spends 5–10 minutes debugging "why is dispatch returning Not Found?" The rule prevents that loop for every future first-time dispatch.

---
