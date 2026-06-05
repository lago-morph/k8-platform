# Spec: `crossplane-render-sandbox`

- **ID**: SKILL-SPEC-ce2015271d
- **Source retrospective**: ../2026-06-05-140.md

## Intent

Bootstrap a working `crossplane render` loop in a fresh, credential-less
sandbox so a Composition's render goldens (SPEC-S9) can be validated and
regenerated locally instead of round-tripping every change through CI. In
the 2026-06-05 phase-3 session this loop was the single highest-leverage
de-risking step — it caught a real cross-source-combine bug before any
push — but getting it running took several non-obvious environment fixes
(missing CLI, stopped docker daemon, a hard-blocked image registry, the
wrong `yq`, and EnvironmentConfig supply). This skill encodes that recipe
so the next session reaches a green render in minutes, not an hour.

## Trigger

- Direct: "render the composition locally", "get crossplane render working",
  "regenerate the render golden", "validate the Composition before pushing".
- Proactive: about to edit a `crossplane/compositions/*.yaml` and
  `crossplane render` / `scripts/composition-render.sh` is not yet known to
  work in this sandbox (first Composition change of the session).
- Negative: do NOT use when CI is the only acceptable authority for the
  golden (e.g. the goldens are version-pinned to a CI-only crossplane
  build and local output is known to drift) — confirm local↔CI parity first
  (see Workflow step 6).

## Inputs

- The repo's `scripts/composition-render.sh` and `tests/chainsaw/versions.env`
  (function version pins).
- The XRD + Composition + fixtures dir for the Composition under test.
- A sandbox with `docker` available (daemon may be stopped) and outbound
  network to at least one public image registry.

## Outputs

- A `crossplane` CLI on PATH, a running docker daemon, mikefarah `yq` ahead
  of any Python `yq`, and the crossplane core render image cached locally.
- A passing `scripts/composition-render.sh` run (render matches golden), or
  a freshly bootstrapped `expected.yaml` golden for a new/changed Composition.
- No repo changes beyond the intended fixture/golden edits.

## Workflow

1. **Install the CLI** if missing: `curl -sSL https://releases.crossplane.io/stable/current/bin/linux_amd64/crank -o /usr/local/bin/crossplane && chmod +x /usr/local/bin/crossplane`.
2. **Start docker** if the daemon is down: `sudo dockerd >/tmp/dockerd.log 2>&1 &` then `docker info` to confirm.
3. **Pre-pull the function image(s)** named in the Composition pipeline from `xpkg.upbound.io` (patch-and-transform, environment-configs) at the versions in `versions.env`. If a pull fails, note which registry.
4. **If the crossplane CORE image won't pull** (render needs `xpkg.crossplane.io/crossplane/crossplane:stable`, which redirects to ghcr.io): pull the same image from Docker Hub and retag — `docker pull crossplane/crossplane:stable && docker tag crossplane/crossplane:stable xpkg.crossplane.io/crossplane/crossplane:stable`. (See AGENTS-MD-b56f4a5eff.)
5. **Install mikefarah `yq`** to `/usr/local/bin/yq` (ahead of `/usr/bin/yq`, which is often the Python `yq` and breaks the normalizer's `yq ea` syntax): `curl -sSL https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64 -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq`. Confirm `yq --version` shows mikefarah.
6. **Parity check before trusting goldens**: render an UNCHANGED Composition that already has a committed golden (e.g. platform-secret). If it matches, the local crossplane version agrees with CI's — local goldens are safe to commit. If it differs only by name-hash/order, the local build drifts from CI; treat local render as structural-only and let CI own the byte-exact golden.
7. **For a Composition that reads an EnvironmentConfig** (function-environment-configs): supply it. Either add a `required-resources.yaml` (the EnvironmentConfig object) in the fixture dir and have the harness pass `--required-resources`, or pass `--context-values=apiextensions.crossplane.io/environment='{...}'`. Without it the env-fed patches render empty.
8. **Run** `scripts/composition-render.sh --xrd … --comp … --fixtures …`. To (re)bootstrap a golden: delete `expected.yaml`, run (bootstrap mode prints normalized output + exits 0), save it as `expected.yaml`, re-run to confirm `OK: rendered output matches`.
9. **Cross-check** with `tests/unit/test_kubeconform_manifests.sh` and `scripts/pre-chainsaw-audit.sh`.

## Concrete examples

**Example 1 — first render of the session fails three ways, then works.**
`scripts/composition-render.sh …` → "Cannot connect to the Docker daemon"
(step 2 fixes it) → "failed to pull …crossplane:stable: ghcr.io 503" (step 4
retag fixes it) → normalizer error `yq: error: argument files` (step 5
mikefarah yq fixes it). Fourth run: renders the full multi-doc stream.

**Example 2 — env-fed Composition, cross-source combine.** A cluster
Composition reads `domain` from the `cluster-network` EnvironmentConfig and
`spec.dns.subdomain` from the XR to build `*.<subdomain>.<domain>`. Supplying
only `required-resources.yaml` renders subnets/zoneId correctly but
`domainName` is empty until the subdomain→env write is a TOP-LEVEL
`environment.patches` entry (AGENTS-MD-89f9b55781). After that fix the render
shows `domainName: '*.platform.render-probe.example.test'` and the golden is
saved.

## Anti-patterns

- Declaring `crossplane render` unusable on the first pull failure without
  trying the docker-start + registry-retag fixes (violates AGENTS §6.12).
- Committing a locally-bootstrapped golden without the step-6 parity check —
  a drifting local crossplane version produces a golden CI can't reproduce.
- Using the system `yq` (often Python `yq`) — the repo normalizer needs
  mikefarah `yq ea`.
- Forgetting to supply the EnvironmentConfig and then "fixing" empty fields
  in the Composition that were only empty because the env wasn't provided.

## Acceptance criteria

1. From a cold sandbox, an unchanged Composition's `composition-render.sh`
   run reaches `OK: rendered output matches` (or a documented parity caveat).
2. A new/changed Composition can have its golden bootstrapped and re-verified.
3. No network/tooling failure is reported as a Composition defect.
4. The recipe touches only `/usr/local/bin`, the docker daemon, and the
   intended fixture/golden files.

## Files this skill creates / modifies

- `/usr/local/bin/{crossplane,yq}` — installed tools (ephemeral sandbox).
- `crossplane/xrds/<name>/render-fixtures/expected.yaml` — bootstrapped golden.
- `crossplane/xrds/<name>/render-fixtures/required-resources.yaml` — the
  EnvironmentConfig(s) supplied to render (when the Composition uses them).
