---
status: contract
---

# Log into platform UIs with SSO

Platform web UIs authenticate against the platform's single sign-on:
one directory account (email + password), one login session, every
participating UI. You never register per-tool accounts, and an
operator disabling your directory account cuts off every UI at once.

## How login works (every participating UI)

1. Open the UI's URL. Instead of a local login form, it redirects to
   the platform sign-in page at `https://auth.platform.<domain>`.
2. The sign-in page forwards you to the **directory login** (the same
   email/password you use for
   [kubectl access](kubectl-access-via-directory-group.md)).
3. After a successful directory login you land back in the UI,
   signed in. While the session lasts, other participating UIs sign
   you in without re-prompting.

Your permissions inside each UI derive from your directory group
membership — the same groups that drive cluster access (see
[Identity mapping](../reference/identity-mapping.md)).

## Participating UIs

| UI | URL | Status |
|---|---|---|
| Account console (manage your own sessions) | `https://auth.platform.<domain>/realms/platform/account` | with this contract's first release |
| Argo CD (GitOps delivery) | operator-provided | planned — follows the auth layer |
| Grafana (observability) | operator-provided | planned — follows the auth layer + storage fix |

The account console is where you can see and end your own active
sessions. Ending a session there takes effect immediately for new
requests from every participating UI.

## Sign out

Use the UI's own sign-out control, then — if you are on a shared
machine — also end the session in the account console. Closing a
browser tab does not end the session.

!!! warning "One password, one place"
    The platform never stores your password: every login form you see
    belongs to the directory. If a platform UI ever presents its own
    password prompt (not the directory's), stop and report it to the
    operator — that is a misconfiguration, not the contract.
