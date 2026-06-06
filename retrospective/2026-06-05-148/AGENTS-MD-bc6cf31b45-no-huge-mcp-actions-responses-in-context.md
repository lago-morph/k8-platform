# agent instruction

**Don't dump huge MCP Actions responses into context; parse the saved file.** "`mcp__github__actions_list` and `mcp__github__actions_get` return hundreds of KB (~380KB) per call because they embed full repository objects. When the harness saves an oversized result to a file, extract only the run id / status / conclusion you need with a one-line `python3 -c` slice of that file — do NOT re-issue the call to re-read it, and don't request the full list when you only need one run's status. For a known run id prefer `actions_get get_workflow_run` over listing; even then, immediately reduce it to the 3-4 fields that matter."

*Grounded in: auto-007 — repeated `actions_list`/`get_workflow_run` calls each returned ~380KB of repo boilerplate to learn a single `status` field; the oversized ones had to be re-parsed from the saved tool-result file.*

# justification

Every status check on a long CI run already re-uploads the whole conversation (§6.10); compounding that with a 380KB response to read one `status: completed` field is doubly wasteful, and it recurs once per poll across a multi-run session. Parsing the saved file with python costs one cheap Bash call and yields exactly the run id + conclusion; re-issuing the MCP call to "read it again" pays the 380KB a second time. The rule is free to follow and removes a steady context tax that, over a long run with several dispatched workflows, adds up to a large fraction of the budget spent learning nothing but `in_progress`.
