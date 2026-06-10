---
name: protocol-reachability-spike
description: >-
  Use when a design decision reduces to "approach A vs approach B" and the
  deciding factor is a single unverified unknown about a transport, protocol,
  provider behavior, or permission boundary — does X pass the sandbox egress
  gateway, does a provider observe a resource kind, does an identity hold a
  permission. Prove that ONE unknown first with the smallest throwaway resource,
  then decide. Trigger phrases: "test ONE thing first", "does the gateway permit
  X", "will this work through the egress proxy", "spike it", "de-risk before
  building", "which approach — A or B". Skip when the unknown is cheap to learn
  during the real build, or the throwaway is as expensive as the real thing.
---

# protocol-reachability-spike

**Source spec:** `retrospective/2026-06-08-184/SKILL-SPEC-05b80b90a7-protocol-reachability-spike.md`
(SKILL-SPEC-05b80b90a7). Decision context: ADR-0008 (the SSM-tunnel choice this
pattern produced).

## Intent

Before committing to an architecture whose viability hinges on a single unverified
unknown, prove that ONE unknown first with the smallest possible throwaway resource, then
decide. In the originating session the SSM-vs-NLB choice hinged entirely on whether the
Anthropic egress gateway would sustain the long-lived SSM `ssmmessages` websocket; a
throwaway `t3.micro` + an `AWS-StartPortForwardingSessionToRemoteHost` + one `curl`
answered it in minutes and settled the whole design before any Terraform or Composition
was written. The cost of *not* spiking is building (or half-building) the wrong
architecture and discovering the blocker late.

## When to use

- A design reduces to A-vs-B and the deciding factor is ONE unknown about a transport,
  protocol, provider behavior, identity, or permission boundary.
- Proactively at the top of a multi-day build whose central mechanism has never been
  exercised in this environment (a new tunnel, a new provider kind, a new auth path).
- **Do not** spike when the unknown is cheap to discover during the real build, when the
  throwaway costs as much as the real architecture, or when both approaches survive the
  answer (then it isn't the deciding unknown).

## Workflow

1. **State the unknown as a yes/no question whose answer flips the decision.** If the
   answer doesn't change which approach you pick, it is not the unknown to spike.
2. **Pick the cheapest primitive that exercises exactly that question** — not the real
   architecture, the minimal proxy (one instance, one MR, one API call).
3. **Stand it up and exercise the unknown.** Use real credentials / the real environment
   so the answer is trustworthy (a kind/fake-cloud answer to a real-cloud question is
   not an answer).
4. **Capture the RAW result verbatim** — the status code, `ssl_verify` value, error
   text, or condition message. Do not paraphrase `HTTP 200 / ssl_verify=0` into "it
   worked"; the raw signal is the evidence and often proves more than the headline (here
   it proved real end-to-end TLS / real-CA verification through the tunnel).
5. **Interpret against the decision:** which approach does the evidence pick? Record the
   verdict + evidence where the decision lives (an ADR, the handoff).
6. **Tear the throwaway down immediately** — the instance AND any IAM/scaffolding it
   needed. Note the teardown so nothing lingers (it accrues cost and, in a
   9-instance-capped account, can block the real build).

## Concrete examples

### Example 1 — SSM websocket vs the egress gateway

Unknown: "Does the Anthropic egress gateway permit the long-lived SSM `ssmmessages`
data-channel websocket?" — the only thing separating the SSM-tunnel and NLB approaches.
Spike: launched a throwaway `t3.micro` with `AmazonSSMManagedInstanceCore`, ran
`aws ssm start-session --document-name AWS-StartPortForwardingSessionToRemoteHost
--parameters host=["example.com"],portNumber=["443"],localPortNumber=["9443"]`, then
`curl --resolve example.com:9443:127.0.0.1 https://example.com:9443/`. Raw result:
`HTTP=200 ssl_verify=0` + real body + "Connection accepted for session". That settled
SSM-over-NLB in minutes (gateway sustains the websocket AND kubectl gets real-CA
verification through the tunnel). Throwaway instance + its IAM role/profile torn down.

### Example 2 — does the classic resource kind dodge a provider bug?

The `SecurityGroupIngressRule` MR wouldn't sync ("Missing Resource Identity After Read").
Rather than rewrite the whole Composition and re-provision a cluster to learn whether the
classic `SecurityGroupRule` avoided the bug, a single standalone `SecurityGroupRule` MR
was applied to the live hub. It got past `observe` (bug avoided) and surfaced the *next*
unknown verbatim — `UnauthorizedOperation: ec2:AuthorizeSecurityGroupIngress` —
pinpointing a missing IAM permission without a full rebuild.

## Anti-patterns

- **Building the real architecture to discover the unknown.** Standing up the full NLB or
  the whole Composition just to learn whether the gateway permits a websocket wastes the
  time the spike saves.
- **Paraphrasing the evidence.** "It worked" loses the `ssl_verify=0` that actually proved
  real-CA verification. Capture the raw signal.
- **Leaving the throwaway running.** A spike instance left up accrues cost and can block
  the real build in a quota-capped account.
- **Spiking a non-load-bearing unknown.** If both approaches survive the answer, the spike
  taught you nothing — spike only the deciding question.

## Acceptance criteria

- [ ] The unknown is stated as a single yes/no question that flips the decision.
- [ ] The throwaway resource is strictly smaller/cheaper than the real architecture.
- [ ] The raw result (status/error/condition text) is captured verbatim, not paraphrased.
- [ ] The throwaway (and its scaffolding IAM) is torn down in the same session.
- [ ] The verdict + evidence is recorded where the decision is documented.
