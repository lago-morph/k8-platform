"""MkDocs hook: render and enforce the per-page stability marker.

Every page in docs/site/ declares front matter `status: stable|contract|draft`
(the docs-before-implementation convention — see docs/site/about.md).
This hook does two things:

1. Injects a visible admonition banner directly under the page's H1
   title, so every published page shows its stability level to the
   reader (scenario authors decide what to build on from this marker).
2. Logs a WARNING for any page whose status is missing or invalid.
   `mkdocs build --strict` — run locally and as the CI gate in
   .github/workflows/docs-site.yml — promotes that warning to a build
   failure, so the convention is enforced mechanically, not memorized.

Registered via `hooks:` in mkdocs.yml.
"""

import logging

# Under the `mkdocs.` logger namespace so --strict counts the warnings.
log = logging.getLogger("mkdocs.hooks.status_banner")

# Marker -> (admonition type, meaning shown to the reader).
# The meanings mirror the table in docs/site/about.md.
STATUSES = {
    "stable": (
        "success",
        "Describes shipped, clean-build-verified behavior. You can build "
        "executable scenarios and automation against this page.",
    ),
    "contract": (
        "info",
        "Describes agreed-but-not-yet-shipped behavior — the target the "
        "implementation must meet. Plan against it, but do not automate "
        "against it until it flips to `stable` on clean-build evidence.",
    ),
    "draft": (
        "warning",
        "Under discussion and may change without notice. Read, but do "
        "not build on.",
    ),
}


def on_page_markdown(markdown, page, config, files):
    status = (page.meta or {}).get("status")
    if status not in STATUSES:
        log.warning(
            "%s: missing or invalid `status:` front matter "
            "(must be one of: %s) — every docs-site page carries a "
            "stability marker (docs/site/about.md)",
            page.file.src_uri,
            ", ".join(sorted(STATUSES)),
        )
        return markdown

    kind, meaning = STATUSES[status]
    banner = f'!!! {kind} "Stability: `{status}`"\n\n    {meaning}\n'

    # Place the banner directly under the page's H1 so it renders below
    # the title; fall back to the very top for pages without one.
    lines = markdown.split("\n")
    for i, line in enumerate(lines):
        if line.startswith("# "):
            lines.insert(i + 1, "\n" + banner)
            return "\n".join(lines)
    return banner + "\n" + markdown
