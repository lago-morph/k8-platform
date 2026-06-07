# agent instruction

Never run `git checkout <ref> -- .` or `git restore --source=<ref> .` to "reset"
or "clean up" the working tree while doing stacked-branch work. It silently
overwrites tracked files with another ref's content, spuriously reverting your
own stack's committed changes in the working tree (the commits survive, but the
tree diverges from HEAD and a careless `git add -A` would commit the reverts). To
discard uncommitted changes use `git checkout HEAD -- <path>` or `git restore
<path>`; to move between branches use `git switch` / `git checkout <branch>`.

# justification

In auto-013 a `git checkout main -- .` issued to "tidy up" between stacked
branches overwrote `compute-gates.sh` and `test_compute_gates.sh` with main's
(pre-PR-171) versions, deleting the `mgmt_live_verify` work from the working tree
while HEAD still carried it. Caught by a system file-change reminder and recovered
with `git checkout HEAD -- .`, but a less-attentive `git add -A && commit` would
have pushed a silent revert into the stack. The `-- .` / `--source` forms target
an arbitrary ref, not HEAD — the footgun is that they look like a harmless reset.
