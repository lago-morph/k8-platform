# agent instruction

When a shell test asserts the presence or absence of a wildcard (a literal `*`)
in a YAML field via mikefarah `yq` (the repo's CI yq), use the `test()` regex
function, never the `==` operator. mikefarah yq treats `*` in the right-hand side
of `==` as a **glob pattern**, so `select(.namespace == "*")` matches ANY value
(and `== "mon*"` matches `monitoring-agent`). Write wildcard detection as
`[.path[] | select(.field | test("\\*"))] | length` and compare the count to 0;
write exact-literal checks as `test("^...$")`. Equality comparisons whose RHS
contains no `*` are safe. Always run yq-based unit tests with mikefarah yq
(`yq --version` → `mikefarah`), not python-yq — they have different `-e` exit
semantics and `==` behavior, so a test can pass locally on python-yq and fail in
CI.

# justification

auto-010 (PR #159): a new `test_hub_addons_appproject.sh` used
`yq -e 'select(.namespace == "*")'` to detect a wildcard namespace. It passed
locally (sandbox had python-yq 0.0.0) but failed in CI on mikefarah yq v4.44.3,
which glob-matched the literal `monitoring-agent` value against `"*"` and
reported a wildcard that wasn't there — reding the unit-tests check. The fix was
to switch to the `test()` regex idiom (the same family
`test_platform_spoke_appproject.sh` already used). Codifying this prevents the
whole class of false-positive/false-negative wildcard assertions and the
local-vs-CI yq divergence that hid it.
