# agent instruction

**Overlap long live-provisioning waits with cluster-independent authoring and review.** "When a step blocks on slow live provisioning (an EKS bring-up is ~20-30 min), do NOT idle — dispatch the cluster-independent code authoring (test harnesses, scripts) and the decision-brief adversarial-review subagents to run during the wait, then do the live validation once the substrate is up."

*Grounded in: auto-015, where P3/P4/P5 authoring and the 6 OI-1 adversarial reviewers ran during the base/management/spoke EKS provisioning waits.*

# justification

auto-015's critical path was three serial EKS provisions (base, management, spoke) at roughly 20-30 minutes each — over an hour of pure waiting if treated serially. Instead the lead agent kicked off each bring-up dispatch and immediately filled the wait with cluster-independent work: authoring the P3 reaper wiring, dispatching P4 and P5 harness-authoring subagents, and running two rounds of three real adversarial reviewers on the IAM-tightening decision brief. By the time the substrate was up, most of the run's code and all of its decision review were already done, leaving the live window for validation only. The marginal cost is bookkeeping the in-flight provisioning run-ids while doing other work; the cost of not doing it is an agent idling through an hour of provisioning, turning a productive unattended run into a slow one. This is the difference between an overnight run that ships a handful of PRs and one that ships a stack.
