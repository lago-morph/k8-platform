#!/usr/bin/env bash
# SKIP_REGISTER lint (FINAL-PLAN §4.6) — the durable-disable register's integrity.
#
# The register (tests/live/SKIP_REGISTER.yaml) is the ONLY durable way to disable
# a live check, AND where a non-`full` profile choice is recorded. This lint makes
# every disable attributable and time-boxed:
#   - every entry (profile_choice / disable_all / each skip) carries
#     reason + owner + expires
#   - no `expires` is in the past (a calendar event must not silently re-enable;
#     past expiry => FAIL); a within-grace (<= GRACE_DAYS to expiry) entry WARNs
#   - the register holds at most N entries (default 12; the message names which
#     to retire)
#   - a disabled SECURITY check carries an `oi:` cross-link
#
# Usage: skip-register-lint.sh [path-to-register]
# Env:   SKIP_REGISTER_CAP (default 12), SKIP_REGISTER_GRACE_DAYS (default 14)
# Exit:  0 clean (warnings allowed); 1 on any violation; 2 usage/parse error.

set -uo pipefail

REG="${1:-tests/live/SKIP_REGISTER.yaml}"
CAP="${SKIP_REGISTER_CAP:-12}"
GRACE="${SKIP_REGISTER_GRACE_DAYS:-14}"

[ -f "$REG" ] || { echo "skip-register-lint: no register at $REG" >&2; exit 2; }
command -v yq >/dev/null 2>&1 || { echo "skip-register-lint: yq required" >&2; exit 2; }

today_epoch="$(date -u +%s)"
fail=0

# Emit one record per entry as 6 tab-separated fields. Tabs are IFS-whitespace,
# so an EMPTY middle field would be collapsed by `read` and shift later fields —
# use a sentinel (∅) for every field and normalize it back to "" in bash.
S='∅'
records="$(yq -r '
  ( (.profile_choice // {}) | select(length>0) | ["profile_choice", (.reason // "∅"), (.owner // "∅"), (.expires // "∅"), (.oi // "∅"), "false"] | @tsv ),
  ( (.disable_all // {})    | select(length>0) | ["disable_all",    (.reason // "∅"), (.owner // "∅"), (.expires // "∅"), (.oi // "∅"), "false"] | @tsv ),
  ( (.skips // [])[]        | [("skip:" + (.check // "?")), (.reason // "∅"), (.owner // "∅"), (.expires // "∅"), (.oi // "∅"), ((.security // false) | tostring)] | @tsv )
' "$REG" 2>/dev/null)"

count=0
if [ -n "$records" ]; then
  while IFS=$'\t' read -r id reason owner expires oi security; do
    [ -z "$id" ] && continue
    [ "$reason" = "$S" ] && reason=""
    [ "$owner" = "$S" ] && owner=""
    [ "$expires" = "$S" ] && expires=""
    [ "$oi" = "$S" ] && oi=""
    count=$((count+1))
    for f in reason owner expires; do
      if [ -z "${!f}" ]; then
        echo "FAIL [$id]: missing required field '$f'" >&2; fail=1
      fi
    done
    if [ -n "$expires" ]; then
      exp_epoch="$(date -u -d "$expires" +%s 2>/dev/null || echo "")"
      if [ -z "$exp_epoch" ]; then
        echo "FAIL [$id]: expires='$expires' is not a valid date" >&2; fail=1
      elif [ "$exp_epoch" -lt "$today_epoch" ]; then
        echo "FAIL [$id]: expired on $expires — retire or renew the entry" >&2; fail=1
      else
        local_days=$(( (exp_epoch - today_epoch) / 86400 ))
        if [ "$local_days" -le "$GRACE" ]; then
          echo "WARN [$id]: expires in ${local_days}d (<= ${GRACE}d grace) — renew soon" >&2
        fi
      fi
    fi
    if [ "$security" = "true" ] && [ -z "$oi" ]; then
      echo "FAIL [$id]: a disabled SECURITY check needs an 'oi:' cross-link" >&2; fail=1
    fi
  done <<< "$records"
fi

if [ "$count" -gt "$CAP" ]; then
  echo "FAIL: register holds $count entries (> cap $CAP) — retire the stalest before adding more" >&2
  fail=1
fi

if [ "$fail" -eq 0 ]; then
  echo "skip-register-lint: OK ($count/$CAP entries, all attributable + unexpired)"
fi
exit "$fail"
