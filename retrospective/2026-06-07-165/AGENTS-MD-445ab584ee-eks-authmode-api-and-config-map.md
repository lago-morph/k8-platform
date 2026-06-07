# agent instruction

**EKS clusters need API_AND_CONFIG_MAP for AccessEntry-based access.** "Any EKS cluster that will be reached via EKS AccessEntries (ArgoCD hub→spoke registration, IRSA-less cross-account access) MUST set accessConfig.authenticationMode to API or API_AND_CONFIG_MAP at create; the EKS default CONFIG_MAP silently rejects AccessEntry create/list with InvalidRequestException."

*Grounded in: auto-012 — the spoke cluster was CONFIG_MAP and the whole AccessEntry trust plane was blocked.*

# justification

The platform-cluster Composition never set `accessConfig`, so the spoke EKS cluster defaulted to `CONFIG_MAP`, under which every downstream step — the XSpokeAccess AccessEntry/AccessPolicyAssociation MRs and the ArgoCD cluster registration — is impossible. The failure mode is not an admission/validation error at apply; it is a late `InvalidRequestException` from the EKS API only when you try to create an Access Entry, so it stays invisible until spoke registration is attempted. One line in the Composition (`accessConfig.authenticationMode: API_AND_CONFIG_MAP`, a non-destructive superset of the default) prevents the entire class. The CONFIG_MAP→API_AND_CONFIG_MAP upgrade is one-way but harmless.
