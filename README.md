# Obot design proposals

This repository is where we collaborate on significant Obot designs before
implementation begins. Each document is an Obot Design Proposal (ODP).

The goal is early architectural feedback, not more documentation. A proposal
should be as short as it can be while still giving reviewers enough context to
challenge the design, compare alternatives, and understand its consequences.

## When to write a proposal

A design proposal is useful when a change:

- introduces or significantly changes an architecture, API, data model, or
  cross-component contract;
- has broad impact, a difficult migration, or a costly rollback;
- has multiple plausible approaches with meaningful trade-offs; or
- would benefit from agreement across contributors before implementation.

The threshold is intentionally qualitative. A maintainer may request a
proposal, and any contributor may choose to write one. Small, local, or easily
reversible implementation changes generally do not need one.

When in doubt, start with a short proposal. Reviewers can decide that no
further design work is needed.

## Lifecycle

```text
Idea -> proposal PR -> discussion and revision -> approval and merge
     -> implementation -> implementation PR + ADR -> merge
```

A merged proposal means the design is accepted and implementation may proceed.
It is a plan, not a promise that every detail will ship unchanged. If
implementation reveals a material architectural change, open a follow-up
proposal before proceeding and link the two proposals through their **Related
ODPs** sections. Do not materially rewrite the merged proposal.

The ADR belongs in the repository that contains the implementation. It records
the concise, durable decision that actually shipped and links back to the
proposal. This repository preserves the earlier design and its discussion.

## Creating a proposal

1. Copy [`templates/design-proposal.md`](templates/design-proposal.md) to
   `proposals/NNNN-short-name/README.md`.
2. Choose the next available four-digit number. Proposal numbers identify
   documents; they do not imply priority or order of implementation.
3. Add every GitHub issue driving the work to the proposal's **Related issues**
   section. Every proposal must have at least one related issue. Use direct
   links and briefly describe each issue's relationship to the proposal when it
   is not obvious.
4. Fill in the sections that help reviewers understand the design. Write
   `Not applicable` where that is genuinely the answer; remove optional
   prompts that add no value.
5. Put diagrams or other supporting files in the same proposal directory and
   link to them with relative paths. Mermaid diagrams may be embedded directly.
6. Open a pull request. Keep it as a draft until it is ready for architectural
   review.
7. Resolve important conclusions in the proposal itself. The document should
   remain understandable without reading the entire PR conversation.
8. Merge the proposal once it is approved.

If two open proposals choose the same number, the later one should take the
next available number before merge.

Merged proposals are not edited merely to mirror implementation details. Small
corrections and links are welcome. Material design changes should be reviewed
explicitly, usually in a new proposal. Link related proposals from each
document's **Related ODPs** section and describe the relationship—for example,
`supersedes`, `extends`, or `depends on`—so the design history remains easy to
follow.

## Reviewing a proposal

Focus review on the decisions that would be expensive to revisit after code is
written:

- Is the problem clear, and are the goals and non-goals appropriate?
- Does the design account for existing systems and constraints?
- Are component boundaries, interfaces, ownership, and data flow clear?
- Were the important alternatives and trade-offs considered?
- Are failure modes, security implications, compatibility, and operations
  addressed where relevant?
- Is rollout reversible, and can the result be validated?
- Are open questions either resolved or explicitly assigned?

Approval means the reviewer believes the design is ready to implement. It does
not mean every minor implementation detail has been predetermined.

## Repository layout

```text
.
├── .github/
│   └── workflows/
│       └── build.yml
├── README.md
├── AGENTS.md
├── scripts/
│   └── validate.sh
├── templates/
│   └── design-proposal.md
└── proposals/
    ├── README.md
    └── NNNN-short-name/
        ├── README.md
        └── optional-supporting-files
```

The proposal list is maintained in [`proposals/README.md`](proposals/README.md).
