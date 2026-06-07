# tests/live/checks/negative

> Runs in: **full only**


Behavioral live checks for the **negative** tier (FINAL-PLAN §4.2 tier→profile map).
Each `*.sh` here is a child check honoring the exit-code contract
(`tests/live/lib/live-lib.sh`): exit 0=pass, 2=allowed skip, 3=expect-full
violation, other=fail. A passing check declares the kind(s) it verifies with
`covers <group>/<Kind>` so the orchestrator can promote an unverified
git-declared kind to a FAIL.
