# Constraint correction #3 (2026-06-07) — disable semantics: a profile, not a switch

**Owner clarification of requirement #2 (disable-able). Apply to FINAL-PLAN.md after the
round-3 incorporation.**

> "On by default is so that we don't 'forget' to do it during implementation. When it
> works, I want to be able to turn off everything but the verification steps, because I
> want it to not take 3 hours to come up."

## What this means

1. **Purpose of on-by-default = anti-forgetting during DEVELOPMENT.** The default-on
   exists so that, while we are actively implementing, we cannot forget to verify what
   we built. It is a development-time safety net first; the FAIL-closed live-evidence
   gate (round-3) is what gives it teeth.

2. **"Disable" is a PROFILE selector, not a binary on/off.** When the platform is
   proven working, the operator must be able to turn OFF the expensive tiers and keep
   ONLY the cheap verification steps, so a routine bring-up is fast (not ~3 hours).
   Concretely, three profiles:
   - **`full` (DEFAULT during development):** after-the-fact verification (L2a) +
     instantiate-on-purpose (L2b) + negative/precondition (L3) [+ e2e]. Nothing is
     forgotten.
   - **`verify-only` (mature/working):** ONLY the fast after-the-fact verification of
     what THIS bring-up actually created/health (L2a). Drops the slow instantiate +
     negative tiers because the mechanism is already proven. This is the "don't take 3
     hours" mode.
   - **`off`:** fully disabled — guarded, audited, NOT used now.

3. **The cost driver is the instantiate-on-purpose (L2b) + negative (L3) tiers** — those
   create throwaway resources and exercise failure paths, which is what makes a bring-up
   slow. The after-the-fact verification (L2a) is cheap (read-only `Describe*`/health on
   resources the bring-up already created) and is what stays on in `verify-only`.

## Required changes to the plan

- Replace the binary disable switch with a **profile selector** (`full` / `verify-only`
  / `off`), `full` as the tested-invariant default.
- Map each test tier to the profiles it runs in (L2a = all non-`off` profiles; L2b/L3 =
  `full` only).
- **The anti-silent-regression invariant holds PER PROFILE:** in `verify-only`, the L2a
  verification set must still actually run, and `all-skipped ⇒ RED` applies to THAT set;
  selecting `verify-only` is an explicit, recorded reduction (the dropped tiers are a
  deliberate choice, never a silent skip). The FAIL-closed live-evidence gate records
  WHICH profile produced the evidence, so a `verify-only` result can't masquerade as a
  `full` result.
- State the intended lifecycle: `full` while a component is under active development;
  the operator may move a proven component/cluster to `verify-only` to keep routine
  bring-ups fast; moving back to `full` is required when that component changes again
  (tie to the coupled-to-the-change rule — a change to a component re-arms `full` for it).
- Keep this consistent with the cost split (expensive EKS/RDS were already after-the-fact
  i.e. L2a — they remain in `verify-only`; the ~3-hour cost being removed is the L2b/L3
  instantiate/negative work).
