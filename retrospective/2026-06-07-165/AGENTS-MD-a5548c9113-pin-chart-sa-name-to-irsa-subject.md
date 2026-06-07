# agent instruction

**Pin a chart ServiceAccount name when an IRSA trust policy hardcodes the subject.** "When an IRSA trust policy hardcodes the OIDC subject system:serviceaccount:<ns>:<name>, pin the consuming Helm chart's serviceAccount.name to <name>; charts default the SA name to the release name, so the sub claim mismatches and AssumeRoleWithWebIdentity is denied with no obvious error."

*Grounded in: auto-012 — the external-dns trust subject was `external-dns` but the ArgoCD-release-named chart created SA `spoke-external-dns`, so external-dns published no records.*

# justification

The XSpokeAccess Composition builds the external-dns IRSA trust policy with the hardcoded subject `system:serviceaccount:external-dns:external-dns`. But the external-dns Helm release is named after the ArgoCD Application (`spoke-external-dns`), so the chart created SA `spoke-external-dns`, whose OIDC sub claim is `system:serviceaccount:external-dns:spoke-external-dns` — a mismatch. `AssumeRoleWithWebIdentity` was denied, but external-dns reported Healthy and simply wrote zero Route53 records; the only symptom was a missing DNS record. Pinning `serviceAccount.name: external-dns` in the chart values fixes it. Any IRSA-backed chart whose trust subject is a fixed SA name is exposed to this; the rule makes the SA-name/subject coupling explicit.
