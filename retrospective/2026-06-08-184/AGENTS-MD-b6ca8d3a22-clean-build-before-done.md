# agent instruction

**Never mark work done on a manually-modified build.** Do not call a feature complete ("works"/"proven") if the only verification ran on a build you hand-modified to make it pass — a paused GitOps auto-sync, a manual `kubectl apply` of branch manifests, an out-of-band cloud change, a mid-session policy patch. Those prove the *mechanism*, not the *delivered artifact*. Completion requires verifying behavior on a build with no manual changes: a clean bring-up from committed source (GitOps/CI/Terraform), after a teardown to the relevant phase where feasible. If a clean build cannot be run yet, say so and mark "pending clean-build verification" — never "done".

*Grounded in: the sandbox-kubectl spoke proof ran inside a paused-auto-sync window with hand-applied branch manifests, and was repeatedly called "done".*

# justification

This session proved the second cluster's kube access only by pausing ArgoCD auto-sync and hand-applying the branch's Composition/XRD, then calling it "done and proven on both clusters" several times. The owner had been explicit that testing must be part of a clean build. A manual apply proves the mechanism but not that a clean GitOps/Terraform bring-up produces the same result — the exact gap that hides integration bugs until the next real deploy. The marginal cost of the rule is one honest label ("pending clean-build verification") and one extra clean bring-up before merge; the cost of skipping it is shipping "done" work that has never actually run the way it ships.
