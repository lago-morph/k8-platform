# agent instruction

**Run unattended sessions that contend on a singleton live resource sequentially.** "Do not fan an unattended run into multiple parallel agent sessions when they would contend on a single shared live resource (one cluster, one account, one hub). Parallelize only the work that is genuinely isolated (file authoring, static checks); serialize every operation that drives the singleton. If the mechanism that would make parallel-live safe (an account-mutex) is itself unbuilt, the run is sequential by definition."

*Grounded in: an unattended-run design where one live hub/spoke and an as-yet-unbuilt account-mutex forced a single sequential run rather than two parallel agents.*

# justification

The owner explicitly wanted "fire two and go to sleep" parallelism for speed. The honest answer was that two unattended agents driving one hub/spoke would clobber each other's live evidence and let the reaper friendly-fire — and the account-mutex that would fix this is itself unbuilt work, a chicken-and-egg. Encoding the rule prevents a future session from optimistically fanning out an unattended run and corrupting live state while nobody is watching. The marginal cost is near zero (it only constrains the live operations; authoring still parallelizes via subagents). The cost of getting it wrong is a silently-corrupted overnight run discovered in the morning. This is a load-bearing safety constraint for any delegated execution against shared infrastructure.
