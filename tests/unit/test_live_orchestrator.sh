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

echo ""
echo "── live: P3 — reaper + account-mutex engage ONLY in full+mutating ──"
# Fake mutex + reaper libs (sourced via the LIVE_MUTEX_LIB / LIVE_REAPER_LIB
# seams) that record their calls to $TMP/p3.log. acquire_rc controls whether the
# fake lease acquire succeeds, so we can prove the fail-closed path too.
make_fake_p3_libs() {
  local acquire_rc="${1:-0}"
  cat > "$TMP/fake-mutex.sh" <<EOF
mutex_acquire() { echo "acquire \$1" >> "$TMP/p3.log"; return $acquire_rc; }
mutex_renew()   { echo "renew \$1"   >> "$TMP/p3.log"; return 0; }
mutex_release() { echo "release \$1" >> "$TMP/p3.log"; return 0; }
EOF
  cat > "$TMP/fake-reaper.sh" <<EOF
reaper_run() { echo "reaper_run \$1" >> "$TMP/p3.log"; return 0; }
EOF
}

# full + mutating: reaper sweeps FIRST, then the lease is acquired, renewed per
# check, and released on exit. A passing after-check keeps the suite green.
reset_checks; mkcheck after a 0 "x/Y"
make_fake_p3_libs 0; rm -f "$TMP/p3.log"
rc="$(run_suite_rc LIVE_PROFILE=full LIVE_MODE=mutating \
        LIVE_MUTEX_LIB="$TMP/fake-mutex.sh" LIVE_REAPER_LIB="$TMP/fake-reaper.sh" \
        LIVE_EXPECT_FULL=x/Y )"
assert_eq "full+mutating with lease held ⇒ exit 0" 0 "$rc"
P3LOG="$(cat "$TMP/p3.log" 2>/dev/null)"
assert_contains "reaper ran"        "reaper_run" "$P3LOG"
assert_contains "lease acquired"    "acquire"    "$P3LOG"
assert_contains "lease renewed"     "renew"      "$P3LOG"
assert_contains "lease released"    "release"    "$P3LOG"
# Order: the reaper sweep precedes the lease acquire (reaper runs FIRST).
assert_eq "reaper_run precedes acquire" "true" \
  "$([ "$(grep -nE 'reaper_run|acquire' "$TMP/p3.log" | head -1 | grep -c reaper_run)" = "1" ] && echo true || echo false)"

# readonly (default): the mutating engagement is skipped entirely — no reaper, no
# lease. The fake libs are never even sourced.
reset_checks; mkcheck after a 0 "x/Y"
rm -f "$TMP/p3.log"
rc="$(run_suite_rc LIVE_PROFILE=full LIVE_MODE=readonly \
        LIVE_MUTEX_LIB="$TMP/fake-mutex.sh" LIVE_REAPER_LIB="$TMP/fake-reaper.sh" \
        LIVE_EXPECT_FULL=x/Y )"
assert_eq "full+readonly ⇒ exit 0 (after tier only)" 0 "$rc"
assert_eq "readonly ⇒ P3 never engaged (no p3.log)" "true" \
  "$([ ! -s "$TMP/p3.log" ] && echo true || echo false)"

# fail-closed: if the lease cannot be acquired, the suite is RED (exit 1) and the
# mutating tiers never run.
reset_checks; mkcheck after a 0 "x/Y"
make_fake_p3_libs 1; rm -f "$TMP/p3.log"   # acquire returns non-zero
rc="$(run_suite_rc LIVE_PROFILE=full LIVE_MODE=mutating \
        LIVE_MUTEX_LIB="$TMP/fake-mutex.sh" LIVE_REAPER_LIB="$TMP/fake-reaper.sh" \
        LIVE_EXPECT_FULL=x/Y )"
assert_eq "lease NOT acquired ⇒ exit 1 (fail-closed)" 1 "$rc"
assert_contains "reaper still ran before the failed acquire" "reaper_run" "$(cat "$TMP/p3.log")"
assert_eq "no release after a failed acquire" "true" \
  "$(grep -q release "$TMP/p3.log" && echo false || echo true)"

assert_summary
