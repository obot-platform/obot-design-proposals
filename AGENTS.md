# Instructions for coding agents

This repository contains design documents, not product implementation. Optimize
for architectural clarity, early collaboration, and a lightweight process.

## Working on proposals

- Read the root `README.md`, `proposals/README.md`, and the proposal template
  before creating or substantially editing a proposal.
- New proposals live at `proposals/NNNN-short-name/README.md`. Use the next
  available four-digit number and a concise kebab-case name.
- Start from `templates/design-proposal.md` and add the proposal to the index in
  `proposals/README.md` in the same change.
- Populate the **Related issues** section with direct links to every GitHub
  issue driving the work. Every proposal must have at least one related issue.
  Do not remove this section or substitute a PR description for it. If the
  relationship is unclear, annotate the link with a short explanation.
- Do not manufacture requirements or decisions. Mark missing information as an
  open question or `TBD`, and distinguish facts from assumptions.
- Keep documents concise, but include enough detail to evaluate interfaces,
  data flow, failure modes, migration, compatibility, security, operations,
  and testing when those concerns apply.
- Prefer concrete examples, schemas, and Mermaid diagrams when they clarify a
  design. Store non-Markdown assets beside the proposal and use relative links.
- Record conclusions from review in the proposal. Do not rely on PR comments as
  the only record of an important constraint or decision.
- A merged proposal should not be silently rewritten to describe a materially
  different design. Create a follow-up proposal and link the old and new
  proposals through their **Related ODPs** sections.
- For every related ODP, state the relationship, such as `supersedes`,
  `extends`, or `depends on`; do not add a supersession relationship unless a
  human has made that decision.
- Preserve authorship.
- Check internal links, headings, proposal metadata, and the proposal index
  before finishing.

## Reviewing proposals

When asked to review, prioritize architectural issues over prose edits. Identify
unclear assumptions, missing constraints, boundary and ownership problems,
failure and rollback behavior, compatibility risks, security concerns, and
alternatives whose trade-offs have not been considered. Make feedback specific
and actionable.
