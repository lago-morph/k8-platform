# agent instruction

**Dispatch live chainsaw before relying on kubeconform alone for v2 Crossplane manifest changes.** "For any PR that migrates Crossplane manifests across a major API-version boundary (e.g. v1 → v2 group rename, XRD apiextensions/v1 → v2), dispatch `chainsaw.yml` against the branch SHA and confirm at least `xrd-establishes` passes BEFORE merging. The static kubeconform schema can accept fields the live admission webhook rejects (observed for `connectionSecretKeys` on v2 XRDs). Schema-pass is necessary but not sufficient."

*Grounded in: 2026-05-26 v1→v2 migration, chainsaw runs 26439096757 and 26440276628.*

# justification

The 2026-05-26 v1→v2 migration cost a hotfix PR (#105) plus two extra chainsaw iterations because the SEG-1 subagent trusted kubeconform alone to validate the v2 XRD shape. Kubeconform's `compositeresourcedefinition_v2.json` schema accepts `connectionSecretKeys` (the field exists in the CRD for back-compat); the live v2 admission webhook explicitly rejects it with `"XR connection secrets aren't supported in apiextensions.crossplane.io/v2"`. The plan flagged this exact possibility in SEG-1 §3 Open Q-3 ("verify after XRD apply"); the subagent skipped that step because kubeconform was green. Cost of NOT adopting the rule: 2 chainsaw re-iterations × ~10 min each + a hotfix PR after Wave 2 merged. Cost of adopting: one extra `chainsaw.yml` dispatch + ~5 min wait, BEFORE merge instead of after.
