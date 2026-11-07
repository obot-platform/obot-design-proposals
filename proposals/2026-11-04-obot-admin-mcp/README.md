# 2026-11-04: Obot Admin MCP server for catalog authoring

- **Authors:** @cloudnautique
- **Created:** 2026-11-04

## Summary

Add an Obot Admin MCP server that helps coding agents author and validate catalog
files. Serve it inside Obot as a vMCP component, reusing existing authentication,
profiles, and audit. Agents write files; Git review and catalog sync apply them.
For catalog entries without stored tool lists, the server points the agent to an
`obot mcp list-tools` CLI command that discovers tools after the user confirms
the launch in a browser.

A prototype exists; this proposal requests architectural approval before merge.

## Related issues

TBD — a driving GitHub issue must be linked before this draft is ready for review.

## Related ODPs

- [Virtual MCPs](../2026-09-01-virtual-mcps/README.md) — extends component runtimes
  while retaining the existing connection and access model.
- [OpenAPI-backed entries](../2026-09-22-openapi-mcp/README.md) — provides context
  for sharing OpenAPI preparation and network policy with catalog sync.

## Problem and motivation

Coding agents need live entry references, tool names, configuration requirements,
and group IDs to write correct catalog files. Local schema validation cannot
verify those values or explain the resulting access grants. General-purpose
administration credentials give an agent more authority than this task needs.

## Goals

- Discover real catalog, tool, identity, and Secret-binding metadata.
- Validate exact file contents using catalog sync's rules and report effective grants.
- Reuse vMCP security without deploying another server.

## Non-goals

Applying changes, publishing Git commits, creating an Admin vMCP automatically,
or changing which catalog entries Git-managed vMCPs can reference.

## Context and constraints

vMCP profiles grant access additively. Git-managed vMCPs currently reference only
entries from configured catalog sources; manually created and built-in entries
have no such reference. Admins therefore create the Admin vMCP through the UI/API.
Open issues track making these entries usable as catalog sources; they are
tracked privately and cannot be linked here.

## Proposed design

Introduce `runtime: builtin` with `builtinConfig.name: obot-admin`. Obot maintains
an immutable catalog entry and registers its handler at startup. It has no
separate public endpoint or global enable flag.

Clients connect through ordinary vMCP OAuth or supported API-key authentication.
Only authenticated internal vMCP component requests reach built-in handlers.
Profiles restrict tools, and the Admin server independently requires the caller
to be a current admin or owner, even if a profile grants broader access.

The gateway serves component requests through an in-memory streaming transport.
Request identity stays isolated per call; cancellation or closing the response
body stops downstream work and releases blocked writes. MCP handling is stateless
across replicas.

Expose nine tools: `list_catalogs`, `search_catalog_entries`, `get_catalog_entry`,
`list_entry_tools`, `search_groups`, `find_user`, `resolve_subjects`,
`list_secret_bindings`, and `validate_catalog_files`. Serve the catalog schema as
an MCP resource and HTTP document.

Validation shares preparation and semantic checks with sync, including references,
configuration, OpenAPI imports, and tool grants. Return diagnostics, file hashes,
and effective access per profile. Save no authored resources and launch no
servers. Limit requests to 1 MiB, 50 files, 200 items, 10 OpenAPI import attempts,
8 MiB of retained schemas, and one minute; apply existing network restrictions.

For entries without stored tools, return an `obot mcp list-tools <entry-id>`
command. The CLI creates a database-backed request, opens the entry's Tools tab,
and waits. The requesting user confirms launch in a browser; API keys cannot
complete requests. Requests expire after ten minutes and accept one result.
Discovery does not automatically save a permanent tool preview.

`obot setup` installs `obot-author-vmcps` for admins and owners. The skill requires
explicit profile subjects, real tool names, exact-file validation, and inspection
of resulting grants. Recommend Kubernetes Secret bindings for credentials;
lookup returns only the names and keys allowed by the UI.

`validate_catalog_files` blocks credentials and keys passed literally in catalog
entries. Values that match credential filters, such as regular expressions for
known key formats, fail validation instead of producing a warning. The agent must
replace them with Secret bindings before validation succeeds.

## Alternatives considered

- **Local validation alone:** cannot check live references or effective access.
- **Dedicated endpoint:** duplicates vMCP authentication and authorization.
- **Separate deployment:** adds runtime cost and credential exchange.
- **Direct launch/apply tools:** widen the agent's authority beyond authoring.

## Trade-offs

Running inside Obot avoids another deployment but adds privileged code and
resource consumption to its process. Browser confirmation adds a step and
requires a reachable UI. Validation reflects current state, not a guarantee
about later sync or upstream tool behavior.

## Risks and open questions

Before merge, the author and reviewers must resolve how to expose incomplete
cached group searches, verify audit handling of credential-bearing input, and
measure concurrent validation and cancellation cleanup. Browser confirmation is
not proof of human presence when an agent can control that browser.

Credential filters also leave open questions:

- Which patterns ship, and can admins configure them? (TBD)
- How are false positives and false negatives handled? Regex filters can miss
  credentials in unrecognized formats and can block values that are not secrets.
- Are blocked values redacted from diagnostics, tool results, and audit records,
  or does the agent see them echoed back?
- Should catalog sync apply the same filters? Without them, existing files with
  literal credentials still sync but fail validation.

## Rollout and migration

Merge the ODP before implementation. Upgrade all serving replicas before adding
built-in components, then have an admin create the vMCP and its profiles. Startup
maintains the built-in entry and tool list. No existing catalog files or
credentials are rewritten. Remove built-in components before downgrading to a
release that cannot understand the runtime.

## Testing and validation

Test direct-access refusal, role loss, profile restrictions, API keys versus
browser confirmation, cross-user request isolation, expiry, and duplicate results.
Exercise streaming cancellation and concurrent callers. Compare validation with
real sync, including persisted configuration, OpenAPI limits, Secret filtering,
and uncached provider groups. Verify that credential filters block known key
formats, and test redaction once that open question is resolved. Complete an end-to-end author/validate/sync test
with real identity-provider users and verify persisted grants.

## References

- [Implementation prototype](https://github.com/cloudnautique/obot/tree/obot-mcp-server)
- [Implementation ADR](https://github.com/cloudnautique/obot/blob/obot-mcp-server/adr/2026-10-30-builtin-mcp-servers.md)
