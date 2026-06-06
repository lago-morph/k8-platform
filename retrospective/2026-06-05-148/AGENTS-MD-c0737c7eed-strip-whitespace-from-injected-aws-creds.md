# agent instruction

**Strip whitespace from sandbox-injected AWS credentials before use.** "When AWS credentials arrive as sandbox environment variables, sanitize them before any AWS call: `AWS_ACCESS_KEY_ID` must be 20 chars and `AWS_SECRET_ACCESS_KEY` 40 chars — if longer, a leading/trailing space was injected. A stray space produces `IncompleteSignature` / `SignatureDoesNotMatch` ('Invalid key=value pair (missing equal-sign) in Authorization header'), which looks like bad creds but isn't. Strip with `tr -d '[:space:]'` into a sourceable helper and re-verify with `aws sts get-caller-identity`. This is a SANDBOX injection artifact — the GitHub Actions secrets are unaffected, so don't conclude the account creds are bad from a sandbox signature error."

*Grounded in: auto-007 — the injected `AWS_ACCESS_KEY_ID` was 21 chars and the secret 41 (each a leading space); every AWS CLI call failed `IncompleteSignature` until stripped, while CI's creds worked fine.*

# justification

The first AWS call in the session failed with a cryptic SigV4 error that reads exactly like an invalid key. Without the length check it's easy to mis-diagnose as "stale/rotated creds" and either stop or chase the account rotation — both wrong, because the bytes were right and only the framing was corrupted by a leading space. The length tell (20/40) and a one-line `tr -d` fix resolve it in seconds; the asymmetry is a one-time sanitize step versus a debugging detour that can wrongly conclude the whole account is unusable. The rule also keeps the sandbox-vs-CI distinction crisp: a sandbox signature error says nothing about whether CI's secrets are valid.
