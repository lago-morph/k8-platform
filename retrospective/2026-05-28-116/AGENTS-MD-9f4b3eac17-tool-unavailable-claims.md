# agent instruction

**Don't declare a tool unavailable until you've tried to install or start it.** "Before reporting 'X is not available in this sandbox' or deferring work on that basis, attempt the obvious installation or activation paths: (a) is the binary already installed but not at PATH? (`which X`, `ls /usr/bin/X /usr/local/bin/X /root/.local/bin/X`); (b) is the daemon installed but stopped? (`systemctl status X`, `service X status`, `pgrep X`, `sudo Xd &`); (c) is there a one-line install? (`curl -fL <release-url> -o /tmp/X && chmod +x /tmp/X`). Report 'unavailable' only after at least one of those attempts has failed with a concrete error. The wrong shape of 'unavailable' claim is `which X` returning nothing — that's an unanswered question, not an answer."

*Grounded in: auto-003 post-retro phase, where the agent twice deferred substantial work ('docker not in sandbox', 'kubectl not in sandbox') that turned out to be wrong on both counts — docker daemon needed `sudo dockerd &`, kubectl was a one-line curl install. The user pointed both out.*

# justification

A false-negative on tool availability has compounding cost: the agent defers work that was tractable; the deferred work shows up as a morning-review item the user has to do themselves; the user's trust in subsequent "unavailable" claims is degraded. Cost of adopting: 2-4 extra tool calls per "unavailable" hypothesis (one `which`, maybe one `ls`, maybe one `sudo Xd &`, maybe one `curl install`). Cost of not adopting: wrongly-deferred work plus user-visible incompetence. In the auto-003 session both deferrals were ~15 minutes of work each that the agent then had to publicly own as a mistake, and they reduced the user's willingness to trust subsequent diagnoses.
