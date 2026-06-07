#!/usr/bin/env bash
# phase=test unit suite for the LIVE orchestrator (FINAL-PLAN §4.4).
#
# Proves THE MECHANISM ITSELF (not any live cloud): the inverted-skip
# tabulation, the LIVE_PROFILE selector, the LIVE_MODE fail-closed coupling,
# the expect-full promotion, the off-register guard, and the
# default-profile-as-tested-invariant. All hermetic — no cluster, no AWS.
#
# Drives tests/live/run.sh against a throwaway $LIVE_CHECKS_ROOT of stub checks
# whose exit codes we control, asserting the orchestrator's overall exit code.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

. tests/lib/assert.sh

RUN=tests/live/run.sh
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# mkcheck <tier> <name> <exit-code> [COVERS-kind] — write a stub check.
mkcheck() {
  local tier="$1" name="$2" rc="$3" covers="${4:-}"
  mkdir -p "$TMP/$tier"
  {
    echo '#!/usr/bin/env bash'
    [ -n "$covers" ] && echo "echo 'COVERS $covers'"
    echo "exit $rc"
  } > "$TMP/$tier/$name.sh"
  chmod +x "$TMP/$tier/$name.sh"
}

reset_checks() { rm -rf "$TMP"/{after,instantiate,negative}; }

# run_suite_rc <env-assignments...> — run the orchestrator, echo its exit code.
run_suite_rc() {
  set +e
  env "$@" LIVE_CHECKS_ROOT="$TMP" LIVE_SKIP_REGISTER="$TMP/REGISTER.yaml" \
    bash "$RUN" >/dev/null 2>&1
  local rc=$?
  set -e
  echo "$rc"
}

printf 'profile_choice: {}\ndisable_all: {}\nskips: []\n' > "$TMP/REGISTER.yaml"

echo "── live: default profile is full (tested invariant) ──────────"
# The literal in the orchestrator's own committed source — changing it is a red diff.
assert_contains "default profile literal == full" 'LIVE_PROFILE_DEFAULT=full' "$(cat "$RUN")"

echo ""
echo "── live: all-skipped ⇒ RED (the inversion) ───────────────────"
reset_checks
mkcheck after a 2
mkcheck after b 2
# No expect-full so the only signal is all-skip. Empty LIVE_EXPECT_FULL.
assert_eq "two skips, zero pass ⇒ exit 1 (RED)" 1 "$(run_suite_rc LIVE_EXPECT_FULL= )"

echo ""
echo "── live: zero checks ⇒ RED (cannot read green verifying nothing)"
reset_checks
assert_eq "no checks at all ⇒ exit 1" 1 "$(run_suite_rc LIVE_EXPECT_FULL= )"

echo ""
echo "── live: a pass ⇒ green (when nothing expect-full is missing) ─"
reset_checks
mkcheck after a 0 "iam.aws.m.upbound.io/Role"
assert_eq "one pass, no missing expect-full ⇒ exit 0" 0 \
  "$(run_suite_rc LIVE_EXPECT_FULL=iam.aws.m.upbound.io/Role)"

echo ""
echo "── live: expect-full + expected-skipped ⇒ FAIL (exit 3) ──────"
reset_checks
mkcheck after a 2 "iam.aws.m.upbound.io/Role"   # skipped, so does NOT cover
assert_eq "git declares Role but no passing check ⇒ exit 3" 3 \
  "$(run_suite_rc LIVE_EXPECT_FULL=iam.aws.m.upbound.io/Role)"

echo ""
echo "── live: a child exit 3 (direct expect-full violation) ⇒ 3 ───"
reset_checks
mkcheck after a 3
assert_eq "child exit 3 ⇒ orchestrator exit 3" 3 "$(run_suite_rc LIVE_EXPECT_FULL= )"

echo ""
echo "── live: a hard FAIL (exit 1/other) ⇒ exit 1 ─────────────────"
reset_checks
mkcheck after a 0 "x/Y"   # a pass so all-skip doesn't mask the fail
mkcheck after b 1
assert_eq "one fail ⇒ exit 1" 1 "$(run_suite_rc LIVE_EXPECT_FULL= )"

echo ""
echo "── live: LIVE_MODE fail-closed (unset/garbage ⇒ readonly) ────"
# live_mode() is the single source for the fail-closed default.
assert_eq "LIVE_MODE unset ⇒ readonly"   readonly "$(env -u LIVE_MODE bash -c '. tests/live/lib/live-lib.sh; live_mode')"
assert_eq "LIVE_MODE=garbage ⇒ readonly" readonly "$(LIVE_MODE=garbage bash -c '. tests/live/lib/live-lib.sh; live_mode')"
assert_eq "LIVE_MODE=mutating ⇒ mutating" mutating "$(LIVE_MODE=mutating bash -c '. tests/live/lib/live-lib.sh; live_mode')"

echo ""
echo "── live: verify-only ⇒ readonly, rejects mutating ────────────"
reset_checks
mkcheck after a 0 "x/Y"
mkcheck instantiate i 0 "x/Z"   # would run in full, must NOT run in verify-only
# verify-only + mutating is rejected outright (exit 1)
assert_eq "verify-only + mutating ⇒ exit 1" 1 \
  "$(run_suite_rc LIVE_PROFILE=verify-only LIVE_MODE=mutating LIVE_EXPECT_FULL= )"
# verify-only runs ONLY the after tier: the instantiate cover (x/Z) must be
# absent from coverage, so requiring it expect-full ⇒ exit 3 proves instantiate
# did not run.
assert_eq "verify-only skips instantiate tier (x/Z uncovered ⇒ exit 3)" 3 \
  "$(run_suite_rc LIVE_PROFILE=verify-only LIVE_EXPECT_FULL=x/Z )"

echo ""
echo "── live: profile=off register guard ──────────────────────────"
reset_checks
mkcheck after a 0 "x/Y"
assert_eq "off without disable_all ⇒ exit 1 (RED)" 1 \
  "$(run_suite_rc LIVE_PROFILE=off LIVE_EXPECT_FULL= )"
# add a valid disable_all entry → off is allowed (exit 0)
printf 'profile_choice: {}\ndisable_all:\n  reason: "proven stack, owner away"\n  owner: "jonathan"\n  expires: "2999-01-01"\nskips: []\n' > "$TMP/REGISTER.yaml"
assert_eq "off WITH valid disable_all ⇒ exit 0" 0 \
  "$(run_suite_rc LIVE_PROFILE=off LIVE_EXPECT_FULL= )"
# an EXPIRED disable_all entry → RED again
printf 'profile_choice: {}\ndisable_all:\n  reason: "stale"\n  owner: "jonathan"\n  expires: "2000-01-01"\nskips: []\n' > "$TMP/REGISTER.yaml"
assert_eq "off with EXPIRED disable_all ⇒ exit 1" 1 \
  "$(run_suite_rc LIVE_PROFILE=off LIVE_EXPECT_FULL= )"
printf 'profile_choice: {}\ndisable_all: {}\nskips: []\n' > "$TMP/REGISTER.yaml"

echo ""
echo "── live: unknown profile ⇒ RED ───────────────────────────────"
assert_eq "unknown profile ⇒ exit 1" 1 "$(run_suite_rc LIVE_PROFILE=bogus LIVE_EXPECT_FULL= )"

assert_summary
