# Escalation Template

Use this verbatim when stopping after 3 consecutive failed fix attempts
or hitting a "no — escalate" entry in `failure-taxonomy.md`. Do not
re-apply a 4th time.

```
I've stopped after <N> attempt(s) verifying claim <kind>/<name> in
namespace <ns>. XR: <xr-name>.

Failing layer: <Claim | XR | Managed:<kind>/<name>>

Conditions on the failing resource:

  Synced=<status> reason=<reason>
    <message>
  Ready=<status> reason=<reason>
    <message>

Recent events (kubectl describe, last 10):

  <verbatim event lines, indented>

Cloud-side state (if reachable):

  <verbatim aws describe-* output, indented>

Attempts so far:
  1. <category> — changed <file>:<lines> to <what>. Re-applied. Result:
     <new condition or "same">.
  2. <category> — ...
  3. <category> — ...

Diagnosis: <one paragraph — what the failure mode actually is, and why
each attempt didn't address it. Be honest about uncertainty. If the
cloud-side state diverges from the k8s-side `Ready` status, say so
explicitly — that's a high-signal data point.>

To unblock I need: <one specific question or action — e.g., "the
provider role lacks `eks:CreateAddon` — confirm whether to add it to the
crossplane IRSA policy in terraform/management/irsa.tf", or "the AWS
account is at the EIP quota — please request an increase or destroy the
unused stack from yesterday">.
```

## Filling it in

- **Failing layer** — walk top-down: claim → XR → managed. Whichever has
  `Synced=False` or `Ready=False` first is the failing layer.
- **Conditions** — copy verbatim from `kubectl get -o jsonpath` (see
  `readiness-conditions.md`). Include the `message` field — that's where
  the actual error lives.
- **Events** — `kubectl describe <kind>/<name> -n <ns> | sed -n '/Events:/,$p' | tail -10`
- **Cloud-side state** — only include if the resource is far enough along
  to exist. If the failure is at composition-render time (no cloud
  resource yet), say "no cloud resource attempted" and skip this section.
- **Diagnosis** — see the terraform-ci-watch escalation template's notes;
  same rules: name the failure mode, admit uncertainty, don't paraphrase
  errors.
- **To unblock** — must be answerable. Single concrete question or
  action.

## What not to do

- Do not re-apply the claim "just to see" after the 3rd failed attempt.
  Each apply burns reconciliation time and can mask the root state.
- Do not delete the claim as a "reset". The user may want to inspect it.
- Do not paraphrase the conditions or events — quote them.
- Do not switch to `terraform-ci-watch` mid-escalation. If the fix turns
  out to require a Terraform change, finish escalating, let the user
  authorize, then start fresh.
