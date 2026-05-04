# logs/

Claude Code session transcripts.

## Capture

A `SessionEnd` hook in `.claude/settings.json` automatically copies the
active transcript to `logs/<session-id>.jsonl` whenever a Claude Code
session ends in this repo.

## Why most files here are untracked

`.gitignore` ignores `*.jsonl` by default. Transcripts often contain
material that should not be committed (sandbox credentials echoed back,
random API responses, internal URLs). Treat each transcript as untrusted
until you've reviewed it.

## Committing a transcript

After reviewing for secrets:

```sh
git add -f logs/<session-id>.jsonl
```

The `-f` is required because of the `.gitignore` rule. Use a normal commit
message and include the file in a docs/chore commit.
