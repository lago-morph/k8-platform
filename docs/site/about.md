---
status: stable
---

# About these docs

How this documentation is organized, what its pages promise, and what
to do when a page lets you down.

## Structure: four kinds of page

The docs follow the [Diátaxis](https://diataxis.fr/) structure. Each
section answers a different kind of question, and pages do not mix
kinds:

| Section | Orientation | Answers |
|---|---|---|
| [Tutorials](tutorials/index.md) | Learning | "Teach me by doing" — a guided first experience |
| [How-to guides](how-to/index.md) | Task | "How do I accomplish this specific goal?" |
| [Reference](reference/index.md) | Information | "What exactly are the fields, names, and guarantees?" |
| [Explanation](explanation/index.md) | Understanding | "Why is it like this? How does it fit together?" |

## The audience rule

Every page describes **public surfaces only**: what a tenant, an
operator, or an engineer can see and do through Git, the Kubernetes
API, published hostnames, and the platform's status surfaces. If a
task can only be explained by reaching into the platform's
implementation, that is a gap in the platform or in these docs — not
something a page may paper over.

## Stability markers

Documentation here is written **before** implementation where that
helps: a page can act as the contract an implementation must meet, the
same way this platform writes tests first. To keep that honest, every
page carries a marker, rendered as a banner under its title:

| Marker | Means | You may |
|---|---|---|
| `stable` | Shipped behavior, verified on a clean build of the platform | Build scenarios, automation, and demos against it |
| `contract` | Agreed behavior that is not shipped yet — the implementation target | Plan and write against it; hold off automating until it flips to `stable` |
| `draft` | Under discussion; may change without notice | Read it, but do not build on it |

A page flips `contract → stable` only when a clean build of the
platform demonstrates the documented behavior — the same "done" bar
the platform holds for everything else. The marker is machine-enforced:
a page without one does not build, so you will never meet an unmarked
page here.

## Conventions

- **Placeholders.** The platform's base domain is an input to each
  deployment, not a fixed value, so pages write hostnames as
  `<name>.platform.<domain>`. Substitute the domain of the deployment
  you are using. The same applies to account-specific values such as
  AWS account IDs and ARNs: docs show their *shape*, never a current
  value.
- **Vocabulary.** Self-service infrastructure requests are Crossplane
  **composite resources (XRs)** — namespaced Kubernetes objects such
  as a platform secret or a database request. Pages name the exact
  `kind` to use.
- **Commands.** Steps are ordinary `kubectl`, `git`, and `curl`
  commands, runnable as written after placeholder substitution.

## When a page lets you down

If you cannot complete a task from these docs alone — a missing page, a
missing fact, or steps that do not match what the platform actually
does — that is a **documentation defect**, and surfacing it is a
contribution. File an issue against
[the platform repository](https://github.com/lago-morph/k8s-platform/issues)
naming the page, what you attempted, and where the docs fell short.
The number of tasks blocked on docs is the metric this documentation
is judged by.
