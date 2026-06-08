# agent instruction

**A red gate is real — fix it or delete it; never re-kick or relegate to a schedule.** A gating check that is red is a real signal every time. Do not "re-kick until green", do not merge around it, do not narrate why it "doesn't really matter". If the code is wrong, fix the code; if the check is non-deterministic (flakes for reasons unrelated to the change — eventual consistency, ordering, timing), the check itself is the defect: make it deterministic (a bounded poll on the real condition that accepts every valid terminal state). There is no "nightly" and no "non-gating" lane to hide a check in — a behavioral check either gates fail-closed at its proper surface or it is fixed/deleted. Re-running is legitimate only for a genuinely external infra blip, and even then the flaky check gets filed and fixed, not normalized.

*Grounded in: a known ASM-deletion flake was re-kicked 3× before being recognized as a deterministic-poll fix, and a "nightly real-AWS" exclusion lane was found shunting real behavioral tests off the gate.*

# justification

The recurring chainsaw red this session was a one-shot `describe-secret` racing AWS Secrets Manager's eventually-consistent deletion. The reflex was to re-dispatch it (three times) and explain why it "wasn't a big deal" — which is precisely how a team learns to ignore red. Separately, the repo had a `CHAINSAW_INCLUDE_REALAWS`/nightly lane that excluded real behavioral tests from the gate and substituted lints, with a manual runbook standing in. Both are the same disease: a check nobody blocks on. The rule costs one deterministic rewrite (a bounded poll) or one deletion; not having it costs every future session re-discovering that red is untrustworthy and burning dispatches on flakes.
