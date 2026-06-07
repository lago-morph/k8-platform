# agent instruction

**Apply new conventions forward-only; do not retrofit already-working systems.** "When adopting a new convention or preferred mechanism, apply it forward-only; do NOT retrofit already-working implementations to the new pattern unless they are broken or the migration has a concrete payoff, because churning working code for stylistic consistency risks regressions for no behavioural gain."

*Grounded in: auto-012 — the user explicitly said "do not go back and retrofit working XPlatformSecrets" when adopting the ESO-default philosophy.*

# justification

When the ESO-as-default decision (ADR 0005) landed, the tempting next move was to migrate the existing, working `XPlatformSecret` usages to plain ESO for consistency. The user explicitly forbade it: "Please do not go back and retrofit working XPlatformSecrets. But going forward follow the philosophy of ESO for lightweight things." This generalizes beyond secrets — a newly-adopted convention is a forward-looking default, not a retroactive mandate to rewrite code that already works. The cost of the rule is occasional mixed mechanisms in the codebase; the cost of ignoring it is needless regression risk and wasted effort churning code whose behaviour was already correct.
