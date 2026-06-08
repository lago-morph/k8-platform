# agent instruction

**Regenerate a generated golden to a temp path, then move it in — never `> the-fixture-file`.** A shell redirect (`cmd > expected.yaml`) truncates/creates the target *before* the command runs, so a tool that diffs against an existing golden will see an empty file, emit a (possibly truncated) diff, and you capture the diff instead of the golden. Generate to a temp file, sanity-check it (expected kinds/length), then `cp`/`mv` it into place; re-run the checker to confirm it matches.

*Grounded in: regenerating a composition render golden with `> expected.yaml` captured a 200-line truncated diff instead of the 462-line render.*

# justification

Regenerating the platform-cluster render golden with `composition-render.sh ... > expected.yaml` produced a corrupt golden: the redirect created an empty `expected.yaml` first, the script's "bootstrap mode" therefore didn't trigger, it diffed the fresh render against the now-empty file, truncated that diff at 200 lines, and that diff got written as the "golden". It took an extra debugging cycle to spot. The rule costs one temp file and a `mv`; skipping it silently produces a golden that passes against itself but encodes garbage.
