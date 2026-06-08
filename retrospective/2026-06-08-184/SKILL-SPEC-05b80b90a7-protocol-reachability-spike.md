# Spec: `protocol-reachability-spike`

- **ID**: SKILL-SPEC-05b80b90a7
- **Source retrospective**: ../2026-06-08-184.md

## Intent

Before committing to an architecture whose viability hinges on a single unverified
unknown — does a transport/protocol pass the sandbox egress gateway, does a provider
observe a resource kind, does an identity hold a permission — prove that ONE unknown
first with the smallest possible throwaway resource, then decide. In this session the
SSM-vs-NLB choice hinged entirely on whether the Anthropic egress gateway would sustain
the long-lived SSM `ssmmessages` websocket; a throwaway t3.micro + an
`AWS-StartPortForwardingSessionToRemoteHost` + one curl answered it in minutes and
settled the whole design before any Terraform or Composition was written.

## Trigger

- A design decision reduces to "approach A vs approach B" where the deciding factor is a
  single unknown about a transport, protocol, provider behavior, or permission boundary.
- Phrases: "test ONE thing first", "does the gateway permit X", "will this even work
  through the egress proxy", "spike it", "de-risk before building".
- Proactive: at the top of any multi-day build whose central mechanism has never been
  exercised in this environment (a new tunnel, a new provider kind, a new auth path).
- **Negative trigger**: do not spike when the unknown is cheap to discover during the
  real build, or when the throwaway resource is as expensive as the real one. Spike only
  the *load-bearing* unknown.

## Inputs

- The competing architectures and the single unknown that distinguishes them.
- Cloud/API credentials available to the sandbox (or a way to get them).
- The minimal primitive that exercises the unknown (one instance, one request, one MR).

## Outputs

- A binary verdict on the unknown, captured with verbatim evidence (status code, error
  text, condition message) in chat and/or the eventual ADR.
- A torn-down throwaway resource (no lingering cost).
- A decision recorded with the evidence inline.

## Workflow

1. State the unknown as a yes/no question whose answer flips the decision.
2. Identify the cheapest resource that exercises exactly that question — not the real
   architecture, the minimal proxy (a t3.micro, a single MR, one API call).
3. Stand it up, exercise the unknown, and capture the *raw* result verbatim (do not
   paraphrase a 200/`ssl_verify=0` into "it worked" — record the actual signal).
4. Interpret against the decision: which approach does the evidence pick?
5. Tear the throwaway down immediately (and any IAM/scaffolding it needed). Note the
   teardown so it isn't left accruing cost or counting against quotas.
6. Record the verdict + evidence where the decision lives (ADR/ handoff), then build.

## Concrete examples

### Example 1: SSM websocket vs the egress gateway (this session)

Unknown: "Does the Anthropic egress gateway permit the long-lived SSM `ssmmessages`
data-channel websocket?" — the only thing separating the SSM-tunnel and NLB approaches.
Spike: launched a throwaway `t3.micro` with `AmazonSSMManagedInstanceCore`, ran
`aws ssm start-session --document-name AWS-StartPortForwardingSessionToRemoteHost
--parameters host=["example.com"],portNumber=["443"],localPortNumber=["9443"]`, then
`curl --resolve example.com:9443:127.0.0.1 https://example.com:9443/`. Result captured
verbatim: `HTTP=200 ssl_verify=0` + the real page body + "Connection accepted for
session". That proved both that the gateway sustains the websocket and that end-to-end
TLS verifies the real upstream cert through the tunnel — settling SSM-over-NLB in
minutes. Throwaway instance + its IAM role/profile torn down afterward.

### Example 2: does the classic resource kind dodge the provider bug?

Later, the `SecurityGroupIngressRule` MR wouldn't sync ("Missing Resource Identity After
Read"). Rather than rewrite the whole Composition and re-provision a cluster to find out
whether the classic `SecurityGroupRule` avoided the bug, a standalone single
`SecurityGroupRule` MR was applied to the live hub. It got past `observe` (bug avoided)
but surfaced the *next* unknown verbatim — `UnauthorizedOperation: ec2:Authorize
SecurityGroupIngress` — pinpointing a missing IAM permission without a full rebuild.

## Anti-patterns

- **Building the real architecture to discover the unknown.** Standing up the full NLB
  or the whole Composition just to learn whether the gateway permits a websocket wastes
  the very time the spike saves.
- **Paraphrasing the evidence.** "It worked" loses the `ssl_verify=0` that actually
  proved real-CA verification. Capture the raw signal.
- **Leaving the throwaway running.** A spike instance left up accrues cost and, in a
  9-instance-capped account, can block the real build. Tear down in the same session.
- **Spiking a non-load-bearing unknown.** If both approaches survive the answer, the
  spike taught you nothing — spike only the deciding question.

## Acceptance criteria

- [ ] The unknown is stated as a single yes/no question that flips the decision.
- [ ] The throwaway resource is strictly smaller/cheaper than the real architecture.
- [ ] The raw result (status/error/condition text) is captured verbatim, not paraphrased.
- [ ] The throwaway (and its scaffolding IAM) is torn down in the same session.
- [ ] The verdict + evidence is recorded where the decision is documented.

## Files this skill creates / modifies

- (transient) a throwaway cloud resource + minimal IAM — deleted at end.
- the decision record (ADR / handoff) where the verdict + verbatim evidence land.
