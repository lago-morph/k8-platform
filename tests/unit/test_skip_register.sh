#!/usr/bin/env bash
# Unit tests for the SKIP_REGISTER lint (FINAL-PLAN §4.6). Hermetic.

set -uo pipefail
cd "$(dirname "$0")/../.."   # repo root

. tests/lib/assert.sh

LINT=tests/live/skip-register-lint.sh
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

lint_rc() {
  set +e
  env "${2:-IGNORE=1}" bash "$LINT" "$1" >/dev/null 2>&1
  local rc=$?; set -e; echo "$rc"
}

FUTURE="$(date -u -d '+90 days' +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d)"
SOON="$(date -u -d '+5 days' +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d)"
PAST="2000-01-01"

echo "── register: the committed register is clean ─────────────────"
assert_eq "committed SKIP_REGISTER.yaml lints clean" 0 "$(lint_rc tests/live/SKIP_REGISTER.yaml)"

echo ""
echo "── register: a complete skip entry passes ────────────────────"
cat > "$TMP/ok.yaml" <<EOF
profile_choice: {}
disable_all: {}
skips:
  - check: tests/live/checks/after/x.sh
    reason: "flaky on cold cache"
    owner: jonathan
    expires: "$FUTURE"
EOF
assert_eq "complete entry ⇒ exit 0" 0 "$(lint_rc "$TMP/ok.yaml")"

echo ""
echo "── register: missing field ⇒ FAIL ────────────────────────────"
cat > "$TMP/missing.yaml" <<EOF
profile_choice: {}
disable_all: {}
skips:
  - check: x.sh
    reason: "no owner/expires"
EOF
assert_eq "missing owner/expires ⇒ exit 1" 1 "$(lint_rc "$TMP/missing.yaml")"

echo ""
echo "── register: expired entry ⇒ FAIL ────────────────────────────"
cat > "$TMP/expired.yaml" <<EOF
profile_choice: {}
disable_all: {}
skips:
  - check: x.sh
    reason: "stale"
    owner: jonathan
    expires: "$PAST"
EOF
assert_eq "expired ⇒ exit 1" 1 "$(lint_rc "$TMP/expired.yaml")"

echo ""
echo "── register: within-grace WARNs but passes ───────────────────"
cat > "$TMP/soon.yaml" <<EOF
profile_choice: {}
disable_all: {}
skips:
  - check: x.sh
    reason: "expiring soon"
    owner: jonathan
    expires: "$SOON"
EOF
assert_eq "within grace ⇒ exit 0 (WARN only)" 0 "$(lint_rc "$TMP/soon.yaml")"

echo ""
echo "── register: disabled SECURITY check needs oi: cross-link ────"
cat > "$TMP/sec.yaml" <<EOF
profile_choice: {}
disable_all: {}
skips:
  - check: irsa-trust.sh
    reason: "temporarily disabled"
    owner: jonathan
    expires: "$FUTURE"
    security: true
EOF
assert_eq "security skip without oi ⇒ exit 1" 1 "$(lint_rc "$TMP/sec.yaml")"
cat > "$TMP/sec_ok.yaml" <<EOF
profile_choice: {}
disable_all: {}
skips:
  - check: irsa-trust.sh
    reason: "temporarily disabled"
    owner: jonathan
    expires: "$FUTURE"
    security: true
    oi: OI-2026-06-07-9
EOF
assert_eq "security skip WITH oi ⇒ exit 0" 0 "$(lint_rc "$TMP/sec_ok.yaml")"

echo ""
echo "── register: profile_choice + disable_all also validated ─────"
cat > "$TMP/profchoice.yaml" <<EOF
profile_choice:
  profile: verify-only
  reason: "mature stack"
profile_pad: {}
disable_all: {}
skips: []
EOF
# profile_choice present but missing owner/expires ⇒ FAIL
assert_eq "profile_choice missing fields ⇒ exit 1" 1 "$(lint_rc "$TMP/profchoice.yaml")"

echo ""
echo "── register: cap N ───────────────────────────────────────────"
{
  echo "profile_choice: {}"; echo "disable_all: {}"; echo "skips:"
  for i in $(seq 1 13); do
    echo "  - check: c$i.sh"; echo "    reason: r$i"; echo "    owner: o$i"; echo "    expires: \"$FUTURE\""
  done
} > "$TMP/overcap.yaml"
assert_eq "14 entries (>cap 12) ⇒ exit 1" 1 "$(SKIP_REGISTER_CAP=12 bash "$LINT" "$TMP/overcap.yaml" >/dev/null 2>&1; echo $?)"

assert_summary
