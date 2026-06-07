# agent instruction

When piping `yq -r '... | @tsv'` (or any tab-separated output) into a bash
`while IFS=$'\t' read -r ...` loop, emit a non-empty sentinel for every optional
field (`(.x // "∅")`) and normalize it back to empty in bash. Tab is an
IFS-whitespace character, so `read` collapses runs of tabs and drops empty middle
fields — shifting every later field one position left and silently corrupting the
parse.

# justification

In auto-013's SKIP_REGISTER lint, an entry with an empty `oi` field but
`security: true` produced `…\t\ttrue`; `read` collapsed the empty `oi` and read
`security` into `oi`, so a disabled security check with no OI cross-link passed
the lint. The unit test caught it; the fix was sentinel-padding every field. This
is a generic bash/yq trap that recurs wherever TSV records carry optional middle
fields.
