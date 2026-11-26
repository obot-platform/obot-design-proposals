# 2026-11-26: Revision-bound approval for Git-backed skill distribution

- **Authors:** @osamakaram
- **Created:** 2026-11-26

## Summary

Offer an opt-in distribution approval check in Obot. Repository registration, synchronization, and metadata queries continue to work while an external review workflow approves the exact packages Obot can serve.

## Related issues

- [obot-platform/obot#8618](https://github.com/obot-platform/obot/issues/8618) requests the distribution control.
- [obot-platform/obot#7991](https://github.com/obot-platform/obot/issues/7991) provides context for Git source discovery and package retrieval.

## Related ODPs

None.

## Problem and motivation

Skill sources and access rules answer where Obot finds skills and who can see them. Operators also need to decide which revisions are safe enough to distribute. A source may contain several skills with independent review outcomes. Sync can replace an indexed skill at any time. An access rule can keep a skill out of an ordinary user's results while a privileged user can still preview and download it.

## Goals

- Preserve the source inventory and current discovery behavior.
- Verify the repository URL, full Git commit, skill directory, and complete package contents at the preview and download boundary.
- Apply the content check consistently to administrative and ordinary HTTP and CLI access.
- Keep scanner selection and review workflow with the operator.

## Non-goals

Running a scanner during synchronization, assigning risk scores, managing skills fetched directly from another registry, and uninstalling copies already on devices are outside this proposal.

## Context and constraints

The Git skill repository controller records a resolved commit when indexing. Preview and download share a materialization path that retrieves the resolved commit. The download endpoint rewrites the skill frontmatter to add Obot's existing provenance fields before packaging the directory.

## Proposed design

Load a versioned approval document from a local operator-controlled file when configured. Each record matches a repository URL, full commit, relative directory, and SHA-256 package digest. The digest covers an ordered manifest of relative paths, file SHA-256 values, and regular or executable Git modes. Reject links and unsupported package entries. Document the digest encoding and publish a golden fixture for external tool authors.

Look up the indexed revision before materialization. Verify the entire materialized skill directory before returning preview bytes or injecting Obot metadata into a download. Missing approval, changed bytes, and unreadable or malformed configured policy all deny delivery. The normal identity and access checks remain in place. Keep source registration and synchronization unchanged so operators can inspect candidates and continue to track upstream. The first version can leave the metadata response schema unchanged and return a clear authorization error to install clients.

## Alternatives considered

- **Access rules alone.** Rules continue to scope users and groups, while privileged users and advancing upstream refs still need revision-specific checks.
- **Only pinned, curated source repositories.** A curated source helps preserve an approved package, but Obot administrators can still register other sources. A source can also contain unrelated packages. Pinning and approval address different parts of the workflow.
- **Synchronous admission webhook.** An external service would offer a richer decision API and more flexible state. The local document handles the initial use case and avoids network failure modes on every download.

## Trade-offs

The file is simple to deploy and audit alongside immutable approval evidence. Operators must own the review and publication path for it. Keeping approval and caching outside Obot means the product can support different scanners and review policies without coupling the catalog to one scanner.

## Risks and open questions

Confirm whether maintainers prefer a file option or a narrow built-in policy provider. Decide whether later versions should report eligibility in metadata so the UI and CLI can show why an install is unavailable. A deployment needs a controlled policy update across replicas. Revocation ends future delivery after the policy update, while already installed copies require device reconciliation.

## Rollout and migration

The option is unset by default. An operator enabling it can begin with an empty approval set, retain the catalog and its access grants, and add verified packages incrementally. Existing databases need no approval migration. The resolver rejects the new revision after sync until a matching approval exists. To preserve a previously approved install while inventory tracks upstream, an operator can also register a source pinned to the approved commit.

## Testing and validation

Cover approved and denied end-service requests, same-repository sibling skills, a new commit after sync, executable mode and byte changes, stale rows, malformed policy, and administrative access. Confirm metadata remains accessible and the unchanged default works on a deployment without policy configured. Test digest parity with an external producer.

## References

- [Obot skill sources](https://github.com/obot-platform/obot/blob/v0.28.2/docs/docs/functionality/skills.md)
- [Skill access policies](https://github.com/obot-platform/obot/blob/v0.28.2/docs/docs/functionality/skill-access-policies.md)
