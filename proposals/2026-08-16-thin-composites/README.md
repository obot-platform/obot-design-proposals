# 2026-08-16: Thin composites

- **Authors:** @njhale
- **Created:** 2026-08-16

## Summary

Remove the embedded component manifests from composite catalog entries and
composite servers. A composite then persists references to its components plus
the state it owns: tool overrides, tool prefixes, and per-deployment choices.
Composite responses carry live component data as response-only details, and
component servers are created and updated from their own catalog entries.

This lets a component server be updated on its own, lets one update on a
composite server update every component server, and removes the separate
component refresh step. Nothing about a running deployment changes without an
explicit update.

## Related issues

- [obot-platform/obot#7028](https://github.com/obot-platform/obot/issues/7028) —
  requests composites that are thinner pointers to their components.
- [obot-platform/obot#7130](https://github.com/obot-platform/obot/issues/7130) —
  reports composite catalog entries that accept invalid component references.

## Related ODPs

None.

## Problem and motivation

A composite catalog entry embeds a snapshot of each upstream component's
manifest, and a composite server created from that entry embeds a second copy of
the corresponding runtime manifests. The composite reads, validates, and creates
component servers from these embedded manifests rather than from the objects
they reference.

When an upstream component changes, an administrator must complete a two-step
manual process before that change reaches a deployed component server:

1. Refresh the composite catalog entry, which re-embeds the component's current
   manifest.
2. Update each composite server built from that entry, which rewrites the
   affected component server.

Neither step can be narrowed. A component server cannot be updated on its own,
and updating a composite server adopts changes for all of its components at
once.

Snapshotting also interacts poorly with state that lives outside the manifest. A
static OAuth credential is stored alongside an upstream component's catalog
entry and read live by every server created from it, while the configuration it
authenticates stays frozen in each composite's snapshot. An administrator who
rotates that credential alongside a configuration change unknowingly breaks
every dependent composite: each one authenticates with the new credential
against the old configuration, and no drift signal reports it.

## Goals

- Remove component manifest snapshots from composites
- Eliminate the explicit "component refresh" step for composite catalog entries
- Enable updating component servers individually
- Enable updating all component servers along with the composite
- Make composite catalog entries and servers always present the current state of
  their component sources
- Keep existing composites working through the rollout

## Non-goals

- Automatically updating deployed component servers
- Changing tool override semantics
- Preserving a point-in-time record of upstream component configuration
- Nested composites, or composites in Power User Workspaces

## Context and constraints

Composite catalog entries ship in Git-synced catalogs alongside other entries,
so whatever replaces the embedded manifests must survive being authored in Git
and applied on every sync.

Composites can act as a form of access control over MCP servers. An
administrator may configure one to expose a chosen set of servers and tools to
users who have no access to the upstream components themselves, so a composite
response has to carry everything needed to deploy and configure it without
granting access to the components it references.

## Proposed design

### The composite catalog entry

The embedded component manifest is removed. A component of a composite catalog
entry stores its reference, its tool overrides, its tool prefix, and one new
field:

```text
MCPServerCatalogEntry.manifest.compositeConfig.componentServers[]
├── catalogEntryID | mcpServerID   # the upstream component
├── toolOverrides
├── toolPrefix
└── sourceDigest                   # see "Generating tool overrides"
```

Component manifests are read from the referenced objects instead, so editing an
upstream catalog entry changes what every composite referencing it reports, and
writes nothing to those composites.

Single-object reads of the entry gain `compositeComponents`, computed per
request and never persisted:

```text
MCPServerCatalogEntry.compositeComponents[]
├── catalogEntryID | mcpServerID
├── name, icon
├── manifest             # the referenced catalog entry's manifest, or the
│                        # referenced multi-user server's in catalog-entry form
├── missing
└── toolOverridesStale
```

The catalog entry page and the tool-override authoring UI render from it. List
responses omit it and keep the aggregate fields they report today, so rendering
a catalog page does not resolve every component of every entry.

### Generating tool overrides

Tool overrides are authored against previews generated from a component's
upstream catalog entry. The preview response now also returns a digest of that
upstream's *runtime identity* — its runtime configuration block and environment
variable keys, and nothing else — and saving the overrides stores that digest as
the component's `sourceDigest`.

A name, icon, description, or resource limit cannot change which tools a server
serves, so editing one leaves the digest unchanged.

### Detecting stale tool overrides

Each pass, the catalog entry controller recomputes every upstream's
runtime-identity digest and compares it with the component's stored
`sourceDigest`. A difference means the overrides were authored against a
different version of that upstream. What it finds goes on the entry's status:

```text
MCPServerCatalogEntry.status
├── components[]     # per component: catalogEntryID | mcpServerID, name, icon,
│                    # toolOverridesStale, missing
├── needsUpdate      # any component stale or missing
└── manifestHash     # excludes sourceDigest
```

`toolOverridesStale` is set when the digests differ, `missing` when the
reference does not resolve. `name` and `icon` are copied from the upstream each
pass and kept at their last values once it stops resolving, so the entry can
still render a deleted component. `manifestHash` is computed with `sourceDigest`
excluded, so a regeneration that produces identical overrides does not move
`lastUpdated`. `compositeComponents` carries these fields through, with
`manifest` resolved per request.

A component with no overrides, or no digest, is never marked stale. Git-authored
entries and pre-existing composites carry no digest.

Regenerating previews for a stale component keeps today's merge: existing
overrides are matched by tool name and preserved, tools the upstream dropped
fall out, and tools it added arrive enabled in the dialog. Nothing changes until
the administrator saves, which stamps the new digest and clears the flag.

### Creating a composite MCP server

The composite MCP server loses its embedded manifests too. A component keeps the
same reference, tool overrides, and tool prefix, plus which components this
deployment has turned off:

```text
ComponentServer
├── catalogEntryID | mcpServerID
├── toolOverrides
├── toolPrefix
└── disabled
```

Creating a composite MCP server records those and nothing else. Everything the
deployment needs is resolved by the controller from the upstream catalog entries
at the moment it creates each component server. Two things follow: validation
moves into the controller, and callers need a way to tell when membership has
settled.

The composite controller materializes membership. Each resolvable catalog-entry
reference becomes a component server built from the upstream catalog entry's
current manifest, carrying that entry reference so it is an ordinary MCP server
that detects its own drift and updates itself. Each multi-user reference becomes
an `MCPServerInstance` of the upstream component server, and the controller
keeps the instance's multi-user configuration in sync with that server, which
owns its own lifecycle.

The controller validates each component manifest as it creates or updates the
component server. Validation cannot stay up front at the API layer: the upstream
catalog entry can change between the request and the moment the controller
resolves it, so the manifest the API would have validated is not necessarily the
one that gets written. Validating where the write happens is what resolving live
costs, in exchange for dropping the immutable snapshot that made up-front
validation sound. A failure is recorded against that component and stops work on
it alone:

```text
v1.MCPServer.Status
└── componentErrors   # component reference -> error; absent means healthy
```

An unresolvable reference is skipped the same way. Partial composite MCP servers
deploy, configure, and serve the components they have.

The settled signal is another new status field:

```text
v1.MCPServer.Status
└── observedGeneration   # the last spec generation the controller fully reconciled
```

The controller sets it at the end of any pass in which every component has been
created, left alone, skipped, or recorded in `componentErrors`, so a degraded
composite still settles. The create and connect paths wait briefly for it to
reach the spec generation, then read component detail. On timeout they return
the composite MCP server with its current component detail rather than an error.

Single-object reads of a composite MCP server gain their own
`compositeComponents`, resolved from its component servers and instances rather
than from upstream entries — this reports what is deployed, not what is
available:

```text
MCPServer.compositeComponents[]
├── catalogEntryID | mcpServerID
├── mcpServerName     # the component server, or the upstream component server
├── manifest          # what that server is running
├── needsUpdate       # its own drift against its own upstream
├── error             # from componentErrors
└── configured, missingRequiredEnvVars, missingRequiredHeaders,
    missingOAuthCredentials, needsURL, previousURL
                      # per component, same meaning as on a standalone server
```

One object serves the deploy, reconfigure, consent, and tool-override flows,
including for a user with no read access to the upstream components.

Configuring resolves URL templates and hostname constraints from the upstream
catalog entry and writes each component's URL and credentials onto its component
server — a remote component's URL is that server's own deployment state. A
multi-user component is configured through its own instance credential, as it is
for a direct connection to the upstream server; nothing is written to that
server. A component whose server does not exist is reported in the response's
component detail and its values are not applied.

### Detecting that an update is available

Drift detection skips component servers today, and a composite's drift is
computed by comparing its embedded snapshots against the entry's. Both change.

A component server detects drift against its own upstream catalog entry through
the existing mechanism, and reports it as its own `needsUpdate`.

A composite MCP server reports `needsUpdate` when its membership, tool
overrides, or tool prefixes differ from its composite catalog entry, or when any
of its component servers reports drift. A multi-user component's shared server
owns its own lifecycle and its drift is not rolled up, because a composite
update cannot clear it. Drift detection computes the combined value each pass
and writes it to status rather than leaving it to be computed per read, because
list responses drive the update badge and bulk update but carry no component
detail. The single-object read reports each component server's own
`needsUpdate`, so the UI can say which component is behind.

### Viewing the diff

The diff changes shape because the manifests being diffed are now slim. **View
diff** on a composite MCP server diffs its manifest against its composite
catalog entry's, which yields exactly the composite's own delta: components
added, components removed, tool override and prefix changes. `disabled` and
`sourceDigest` are stripped so deployment state and bookkeeping never read as
changes. Each component server has its own diff against its own upstream catalog
entry, so an administrator can see a component's manifest changes without the
composite composing them.

### Updating a composite MCP server

Updating a composite MCP server no longer starts by refreshing its catalog
entry. With nothing embedded there is nothing to refresh, so `POST
.../entries/{entry_id}/refresh-components` is removed and the two-step process
collapses into one action.

The update endpoint rebuilds the composite MCP server's manifest from its
composite catalog entry — taking membership, tool overrides, and tool prefixes
from the entry and carrying each surviving component's `disabled` forward, since
`disabled` has no counterpart on the entry — validates it, and writes it
together with a new spec field:

```text
v1.MCPServer.Spec
└── update   # set by the update endpoint, consumed by the composite controller
```

Both land in one write and the endpoint returns without waiting.

Today the endpoint merges the stored manifest over the rebuilt one, which lets
stored fields shadow the entry's changes permanently. The rebuilt manifest
therefore takes administrator overrides only from the request body; an override
that is not resent is not carried over.

The composite controller consumes `update`: it rebuilds every enabled component
server from its upstream catalog entry, preserving the component's URL when it
still satisfies the hostname constraint, validates each rebuilt manifest before
writing it, and clears the field only after all component work. The update runs
in the controller: an interrupted pass retries, a failing component stops no
sibling, and a component already matching its upstream is not rewritten. A
rewritten component server is shut down softly — its deployment is recreated on
the next request and its volumes survive.

Membership reconciliation runs against the newly adopted manifest, so a
component the entry added is created and a component it removed is deleted.
Deletion is the only path that removes a component server, and an unresolvable
reference is never treated as a removed member.

### Updating a single component server

Component servers use the existing drift, diff, and update flow against their
own upstream catalog entries. Four exclusions are removed: drift detection skips
servers with a composite parent, the update endpoint rejects them, the general
server list hides them, and the deployment view's update action excludes them.
No composite-specific update path is added. Component servers then appear with
**Update** and **View diff** in the administrator deployment view, and updating
one touches neither its siblings nor the composite's tool overrides.

### Deleting an upstream component

Deleting an upstream catalog entry that composites reference returns the same
409-with-dependencies response that deleting a referenced multi-user server does
today, with a force option that hard-deletes — an administrator otherwise has no
way to know which composites depend on it.

Force is safe because a composite tolerates missing components. Running
composite MCP servers keep operating on their component servers' last manifests,
new deployments materialize without the missing component, and the composite
catalog entry reports it as `missing`, rendered from the stamped name and icon,
until an administrator removes the reference.

### When an upstream is removed from Git, or is invalid

A reference that does not resolve is no longer an error that blocks the whole
entry. The catalog sync controller applies a composite catalog entry as
authored; skipping it, as it does today, would remove the whole composite from
the catalog over one missing component. The dangling reference surfaces as
`missing`, the same signal a deleted upstream produces.

Creating a composite catalog entry through the API rejects a reference that does
not resolve. Updating one does not re-check references: creation is the only
moment a typo is distinguishable from an upstream deleted later, and an entry
whose component was deleted must stay editable so the administrator can fix it.

An upstream that resolves but whose manifest is invalid — a removed tunnel
reference, a lowered resource maximum — fails validation when the controller
tries to create or update that component server. The error lands in
`componentErrors` and surfaces on the component's detail; the rest of the
composite is unaffected.

## Alternatives considered

**Composite-specific storage and APIs.** Dedicated types would give composites
cleaner boundaries than config structs inside the shared manifest. Getting there
means migrating the catalog, deployments, Git sources, configuration flows, and
UI in one motion, none of which is necessary to remove the embedded manifests.

## Trade-offs

- Removing the snapshots removes the point-in-time record of upstream
  configuration: two deployments made at different times can differ with no
  change to the composite catalog entry. Each component server's manifest still
  records what is running.
- A composite MCP server's stored `needsUpdate` combines its own drift with
  drift in its component manifests; only single-object reads distinguish them.

## Rollout and migration

Backend and UI ship together; no data migration. Stored composites decode into
the slim types, dropping the removed fields on read and persisting the slim
shape on their next ordinary write. Component servers already carry their own
manifests, including per-deployment URLs, so nothing is lost.

The 409-with-force protection on deleting an upstream component catalog entry
ships after everything else. Until it lands, a deletion behaves as it does today
and the composite degrades to a missing component.

Component drift the embedded manifests concealed becomes visible at rollout, so
the number of composites reporting a pending update will jump even though
nothing changed upstream. Release notes must say so.

Rollback is not supported. Only each component's manifest is removed, not the
component list, so a build expecting embedded manifests decodes every
component's manifest as empty and overwrites each component server's manifest
with it.

## Testing and validation

**Authoring.** Creating a composite catalog entry with an unresolvable reference
is rejected; updating an entry whose component was deleted succeeds. A
Git-synced entry with a dangling reference is applied and reports the component
missing. Entry responses carry hydrated component manifests and store none;
editing an upstream component catalog entry changes what the composite entry
reports with no write to it.

**Deploying and configuring.** A composite MCP server created from references
materializes a component server or instance per resolvable reference and deploys
without the rest. A user with no access to the upstream components configures
every component from the composite's own response, one request; connecting
reaches each component's tools under the composite's prefixes and tool
overrides.

**Updating.** Changing a non-runtime field of an upstream component catalog
entry sets `needsUpdate` on the component server and on its composite MCP
server, and leaves the composite catalog entry's `needsUpdate` false — the entry
reports tool-override staleness, not manifest drift. Updating the component
server alone adopts the change and touches nothing else. Updating the composite
MCP server adopts the entry's membership, tool overrides, and prefixes and
updates every enabled component server from its own catalog entry; a failing
component reports its error, stops no sibling, and a retry is a no-op for the
rest. Volumes survive a component rebuild driven by a composite update; a
component updated directly follows the standard update path, which shuts the
server down hard.

**Tool override staleness.** Changing an upstream component catalog entry's
runtime configuration sets `toolOverridesStale` on that component and
`needsUpdate` on the composite catalog entry; changing its description sets
neither. Regenerating and saving clears `toolOverridesStale` and preserves
untouched overrides. Components of Git-authored entries are never marked stale.

**Deleting an upstream.** Deleting a referenced upstream component catalog entry
409s with the dependent composites; force deletes it. Running composite MCP
servers keep serving, the composite catalog entry renders the missing component
by its stamped name and icon, and removing the reference deletes the component
server and its credentials.

## References

None.
