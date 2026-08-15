Perform a CONTENT health check of the Obsidian vault in the current working
directory. Read wiki/index.md first, then read the pages in wiki/. Structural
checks (frontmatter schema, dates, index coverage, link targets, reverse links)
are already covered by a separate tool: ignore them entirely.

Look only for these three things:

1. CONTRADICTIONS. Two or more wiki pages that assert incompatible things:
   conflicting numbers, frequencies, targets, schedules, rules, preferences, or
   recommendations. Example of the kind of thing that must be caught: one page
   allowing one quality run a week while another prescribes five to six.
2. SUPERSEDED CLAIMS. A claim on an older page that a newer source page has
   overtaken. Use the created/updated frontmatter dates to decide which is newer.
3. MISSING CONCEPT PAGES. An idea, theme, or practice referenced on three or
   more pages that has no page of its own yet.

Rules:
- Read widely enough to be confident. Quote the conflicting text and name the
  exact page files.
- Report only findings you can evidence from the text you actually read. Do not
  speculate, do not pad, and do not restate structural or stylistic nits.
- A difference in scope, context, or time period is not a contradiction. Say so
  rather than reporting it.
- If there is genuinely nothing to report in a section, write exactly
  "None found." under that heading. Never manufacture a finding to fill space.
- Do not propose that any change be applied automatically. Suggestions are for
  the vault owner to decide on.

Return plain Markdown only, no preamble, using exactly these headings:

## Contradictions
## Superseded claims
## Missing concept pages
## Summary

Under Summary give one line: the count of findings in each of the three
categories.
