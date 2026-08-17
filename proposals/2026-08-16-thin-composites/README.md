# 2026-08-16: Thin composites

- **Authors:** @njhale
- **Created:** 2026-08-16

## Summary

Remove the embedded component manifests from composite catalog entries and
composite servers. A composite then persists references to its component sources
plus the state it owns: tool overrides, tool prefixes, and per-deployment
choices.

Composite responses carry live component data as response-only details. Each
component server reports drift against its own catalog entry and adopts changes
through the standard server update flow, and updating a composite server applies
every pending component update before adopting the composite's own curation
changes. This removes the separate component refresh step without automatically
changing running deployments.

## Related issues

- [obot-platform/obot#7028](https://github.com/obot-platform/obot/issues/7028) —
  requests composites that are thinner pointers to their components.
- [obot-platform/obot#7130](https://github.com/obot-platform/obot/issues/7130) —
  reports composite entries that accept invalid component references.

## Related ODPs

None.

## Problem and motivation

A composite catalog entry embeds a snapshot of each upstream component's manifest,
and a composite server created from that entry embeds a second copy of the
corresponding runtime manifests. The composite reads, validates, and creates
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

Snapshotting also interacts poorly with state that lives outside the manifest.
A static OAuth credential is stored alongside an upstream component's catalog
entry and read live by every server created from it, while the configuration it
authenticates stays frozen in each composite's snapshot. An administrator who
rotates that credential alongside a configuration change unknowingly breaks
every dependent composite: each one authenticates with the new credential
against the old configuration, and no drift signal reports it.

## Goals

- Remove component manifest snapshots from composites
- Eliminate the explicit "component refresh" step for composite catalog entries
- Let administrators update a single component through the standard server
  update flow
- Make one update action on a composite server adopt everything it is behind on
- Make composite catalog entries and servers always present the current state of
  their component sources
- Keep existing composites working through the rollout

## Non-goals

- Automatically update deployed components
- Change tool override semantics
- Preserve a point-in-time record of source component configuration
- Support nested or multi-user composites
- Support composites in Power User Workspaces

## Context and constraints

A catalog-entry component references a single-user catalog entry and becomes a
child MCP server for each composite deployment. A multi-user component
references an already-deployed shared server and becomes a per-user instance of
it. A controller reconciles those children, connect and configure operations
wait for it to finish, and requests to a running composite are served from the
children rather than from the embedded manifests.

Composites ship as catalog entries in remote sources alongside every other
entry. Whatever replaces the embedded manifests has to survive being authored in
a source and resolved on every sync.

Composites can act as a form of access control over MCP servers. An
administrator may configure one to expose a chosen set of servers and tools to
users who have no access to the upstream components themselves, so a composite
response has to carry everything needed to deploy and configure it without
granting access to the components it references.

## Proposed design

A composite persists references and the state it owns; everything else resolves
from the referenced objects when it is needed.

### Data model

Remove the embedded manifests from the catalog and runtime composite config
types. The runtime type gains `url` for the per-deployment value currently
carried inside the embedded runtime manifest.

```text
Before  # apiclient/types, persisted in the v1 spec manifest, client-authored

# CompositeCatalogConfig.componentServers[]
CatalogComponentServer
├── catalogEntryID | mcpServerID
├── manifest        # embedded MCPServerCatalogEntryManifest of the component
├── toolOverrides   # curated allowlist, renames, descriptions
└── toolPrefix

# CompositeRuntimeConfig.componentServers[]
ComponentServer
├── catalogEntryID | mcpServerID
├── manifest        # embedded MCPServerManifest of the component, holding the
│                   # per-deployment URL
├── toolOverrides
├── toolPrefix
└── disabled        # per-deployment

After

CatalogComponentServer            ComponentServer
├── catalogEntryID | mcpServerID  ├── catalogEntryID | mcpServerID
├── toolOverrides                 ├── toolOverrides
└── toolPrefix                    ├── toolPrefix
                                  ├── disabled  # per-deployment
                                  └── url       # per-deployment
```

### Reading a composite

The single-object reads — `GET /api/mcp-servers/{mcp_server_id}` and
`GET /api/mcp-catalogs/{catalog_id}/entries/{entry_id}` — gain
`compositeComponents`, a response-only list computed per request, never
persisted, and ignored if a client includes it in a write. List responses keep
the aggregate state they already report and omit the per-component detail, so
the deploy, reconfigure, consent, and curation flows read one object before
opening.

```text
Wire only  # apiclient/types, computed per request, never persisted

MCPServerCatalogEntry.compositeComponents[]
CatalogCompositeComponentDetails
├── catalogEntryID | mcpServerID
└── manifest              # MCPServerCatalogEntryManifest of the live source

MCPServer.compositeComponents[]
CompositeComponentDetails
├── catalogEntryID        # empty for a multi-user component
├── mcpServerID           # the component server, or the shared server
├── manifest              # MCPServerManifest of what is running
├── needsUpdate           # this component's own drift
├── deploymentStatus      # this component's own status
└── MCPServerConfigState  # configured, missingRequiredEnvVars,
                          # missingRequiredHeaders, missingOAuthCredentials,
                          # needsURL, previousURL
```

A catalog-entry read resolves each reference to its current upstream catalog
entry or shared server. A composite-server read resolves the children that are
actually running, reusing the component servers it already loads to report
aggregate configuration state. A reference whose source has been
deleted is reported as a missing component rather than failing the read.

### Authoring and syncing composite entries

Creating or updating a composite entry validates each reference against the live
object it names: the reference must resolve within the composite's catalog, a
`catalogEntryID` must name a single-user, non-composite entry, and an
`mcpServerID` must name a multi-user server. A reference that does not resolve
rejects the write — today creation silently drops such a component, and updates
do not check at all.

A source-synced composite resolves the same way. Portable references — an entry
key within the same source, or a source-qualified key across sources — still
resolve to stored entries on every sync, but resolution no longer embeds
anything. A reference that cannot be resolved remains a sync error that skips
the entry rather than publishing one that cannot deploy.

`POST /api/mcp-catalogs/{catalog_id}/entries/{entry_id}/refresh-components` is
removed. Nothing is left for it to refresh.

Deleting a component source is not blocked by the composites that reference it,
and the dangling reference behaves as removed wherever it is consumed: the entry
read reports the component as missing, a new deployment materializes without it,
and a deployed composite reports a pending update — its membership now differs
from what the entry can deploy — whose adoption deletes the orphaned child. The
stored reference itself disappears the next time the composite is edited, and a
source-synced composite whose source still carries the reference reports a sync
error until the source is fixed.

### Deploying a composite

Creating a composite server records the component references, overrides, and
prefixes from its entry, plus the user's `url` and `disabled` choices. The
materializing controller then reconciles membership only:

- create a child server for a new catalog-entry reference from the live entry;
- create an instance for a new multi-user reference;
- delete a child whose reference was removed; and
- never rewrite an existing child.

A child server is built from the component entry's current manifest and carries
its own catalog entry reference like any standalone server. Configure operations
resolve URL templates and hostname constraints from the live entry and persist
only the user's `url` on the component. Static OAuth credentials and the
configuration they authenticate now resolve from the same live catalog entry, so
a live credential can no longer be paired with stale embedded configuration.

### Drift and updates

Component servers use the existing drift, diff, and update flow against their
own catalog entries. Today both halves are switched off for composite children:
drift detection skips any server with a composite parent, and
`POST .../mcp-servers/{mcp_server_id}/trigger-update` rejects component servers
outright. Both exclusions are removed. An administrator updates a component from
the existing deployment view without touching its siblings or the composite's
curation, and **View diff** on a component compares its configuration against
its own catalog entry.

A composite server reports `needsUpdate` when its membership, overrides, or
prefixes differ from its catalog entry, or when any enabled component reports
its own. Clients that need to tell the two apart read the per-component details.
**View diff** on the composite compares its curation — membership, overrides,
and prefixes — against its entry; `url` and `disabled` belong to the deployment
and never appear in a diff. A composite catalog entry itself reports no update
state: its response always presents current sources, so the entry-level
`needsUpdate` that today tracks snapshot drift is removed along with the
snapshots.

Updating a composite applies components first, then curation:

1. Attempt every pending member component update. Failures are reported per component
   and do not stop the others.
2. Adopt the composite's own catalog changes — membership, overrides, and
   prefixes, preserving each surviving component's `url` and `disabled` — only
   once every component update has succeeded.

The order is forced by curation semantics. Tool overrides are an allowlist keyed
by tool name, curated against a component's tool list at a moment in time. A
component that is newer than its curation is safe: unknown tools stay hidden and
overrides for removed tools sit inert. Curation that is newer than a deployed
component is not: it can enable or rename tools the running component does not
serve, silently shrinking the composite's exposed tool set. Updating components
before adopting curation keeps every intermediate state in the safe direction,
which is also why there is no separate update-all action — one **Update** on the
composite adopts everything it is behind on. A partial failure leaves the
curation unadopted and the action retryable, with already-updated components
no-ops on retry.

Composite health stops being a constant. `deploymentStatus` on a composite
becomes the worst status among its enabled components, a multi-user component
contributing its shared server's status and a disabled component contributing
nothing.

### Configuration and tool curation

Deploy, reconfigure, and OAuth consent forms read the component details and
continue submitting configuration in one composite request. The existing
per-component reveal behavior remains unchanged.

Tool curation keeps its current preview-and-save flow. The preview starts an
ephemeral server from the live component entry rather than an embedded manifest.
Saved overrides remain an allowlist: new tools stay hidden on a curated
component, removed tools leave inert overrides, and a component with no
overrides continues to expose all tools. Updating a component never changes the
composite's saved curation.

### User interface

The composite catalog-entry page loses its refresh banner, its refresh action,
its update badge, and the per-component diff dialog that compares each embedded
manifest with its live source. Component cards render live component details.

The composite server page keeps its update indicator, its **Update** action now
applies pending component updates before the composite's own changes, and its
**View diff** narrows to the composite's own curation. Component servers regain
**Update** and **View diff** in the administrator deployment view, each
component's configuration reviewed against its own catalog entry. End-user
configuration flows are unchanged.

## Alternatives considered

**Automatically snapshot component manifests.** A controller could refresh every
dependent composite whenever a source changes, removing the manual refresh while
keeping the embedded shape. It retains the duplicate state and the
whole-composite adoption step, and it turns every source edit into write
amplification across all dependent composite entries — with the deployment-level
update still to perform afterward. It also forfeits the review point the manual
refresh at least implied, without gaining the per-component update this proposal
is after.

**Embed the manifests in status.** Moving the snapshot from spec to status keeps
reads self-contained and takes manifests out of the write path. But the
duplicate state remains, every source edit still fans out into status writes
across every dependent composite, and a status-resident cache can go stale in
exactly the ways the embedded spec does today — it changes where the copy lives,
not that there is a copy.

**Fetch each component separately.** Clients could resolve component references
themselves against the existing catalog-entry and server APIs. That turns one
configuration read into a request per component, and it breaks the
access-control use: a user who may deploy a composite without read access to its
components would fail before deployment on reads the composite is supposed to
encapsulate.

**Hydrate the existing manifest fields on read.** Keeping the wire shape and
filling `manifest` from the live source on every read would avoid client
changes. But stored and computed data become indistinguishable in a single
field, and a write that includes a manifest is either silently discarded or
accepted as state the server no longer honors — both worse than a shape that
says what it is.

**Composite-specific storage and APIs.** Dedicated types would give composites
cleaner boundaries than config structs inside the shared manifest. Getting there
means migrating the catalog, deployments, Git sources, configuration flows, and
UI in one motion, none of which is necessary to remove the embedded manifests;
it remains open as a later refactor.

## Trade-offs

Removing the embedded manifests also removes a point-in-time record of source
configuration. Each child manifest still records what is running, but a catalog
composite always reflects its current sources. The composite server's update
flag combines parent curation drift with component drift, so clients must
inspect component details to distinguish them. And because curation adoption
waits for every component update to succeed, one failing component holds the
composite's own changes back until it is fixed — the price of never letting
curation run ahead of a deployed component.

In exchange, source changes no longer amplify into writes across composite
entries, component deployments use the standard reviewable update path, and live
credentials cannot be paired with stale embedded configuration.

## Risks and open questions

### A composite entry no longer pins what it deploys

The embedded manifest is an exact, reproducible record of the component
configuration a composite intends to deploy, and tool overrides are curated
against that exact manifest. With only a reference stored, what a composite
deploys depends on when it is deployed, two deployments made at different times
can differ with no change to the composite itself, and overrides are no longer
anchored to a known component revision.

### New deployments see component changes immediately

Existing deployments still require an explicit update, but catalog presentation
and new deployment forms reflect a changed component with no review by the
administrator who published the composite entry, or by whoever controls its Git
source when the entry is source-synced.

### Should stale tool curation be signaled?

Overrides stay safe when a component's tool list changes, but safe is not
current: nothing tells an administrator that re-curation could expose useful new
tools or clear dead overrides, and with the embedded manifest gone the composite
no longer holds the state its curation was authored against. The proposed
direction records just enough to detect the divergence:

1. Generating tool previews for a component returns the digest of the component
   source's current manifest alongside the previews.
2. Saving the curation stores that digest as the component's `sourceDigest`. A
   source-synced composite stamps the digest when sync first resolves the
   component and restamps it whenever the component's overrides change,
   preserving it otherwise.
3. A controller compares each component source's current digest against the
   stored `sourceDigest` and records a per-component `toolOverridesNeedUpdate`
   in the entry's status, setting an entry-level `needsUpdate` when any
   component is flagged.
4. Both flags flow through the entry response: `needsUpdate` drives the catalog
   entry's status badge, and `toolOverridesNeedUpdate` on the component details
   drives a badge on each affected component.

## Rollout and migration

Backend and UI ship in one release with no phased gate: the refresh action and
the component details replace one another, and no compatibility window exists in
which both shapes are written.

There is no data migration. Stored composites decode into the slim types — the
removed fields are dropped on read — and each object persists the slim shape on
its next ordinary write. The one value that would otherwise be lost is the
per-deployment URL, which today lives inside the embedded runtime manifest of a
remote component whose catalog entry constrains a hostname. A one-time pass at
upgrade copies that value into `url` on each existing composite server before
anything is written slim. Components with a fixed or templated URL need no
backfill, because those values come from the component entry.

**Observability.** Component drift that the embedded manifests concealed becomes
visible as pending updates on component servers and on their composites, so the
number of composites reporting a pending update rises at rollout with nothing
having changed upstream. Release notes should say so, or it reads as a
regression.

**Rollback.** Not supported. A build that expects embedded manifests reads a
slim composite as having no component configuration, and membership
reconciliation applies that emptiness to the children, deleting component
servers and their credentials.

## Testing and validation

Validation follows the lifecycle, in the order an administrator and a user meet
it.

**Authoring a composite.** A composite catalog entry is created through the API
and through a remote source, with a catalog-entry component and a multi-user
component. Its response carries component details resolved from the live entries
and shared servers, and stores no component manifest. Editing a component entry
changes what the composite entry reports on its next read, with no write to the
composite and no change to anything already deployed.

**Validating references.** A reference that does not resolve rejects the write,
as does a `catalogEntryID` naming a composite or a multi-user entry, and an
`mcpServerID` naming a single-user server. A remote source carrying those same
references reports them as sync errors rather than publishing an entry that
cannot be repaired afterward. A `compositeComponents` field sent in a write
payload is ignored rather than stored. Deleting a component entry after
authoring leaves the composite readable and deployable, reporting that component
as missing and deploying without it, while a source that still carries the
reference reports a sync error.

**Configuring and connecting as a user.** A user who can read the composite but
none of its components deploys it, and the deploy form renders every component's
environment variables, headers, and hostname from the composite's own response.
One configure request carries values for all of them and the composite reports
itself configured only once every enabled component is. Connecting through the
composite reaches each component's tools under the composite's prefixes and curated
set, and a component requiring interactive OAuth completes consent through the composite.

**Updating.** Changing a component entry leaves the deployment serving its
original configuration, and reports a pending update on that component server
and on its composite. Updating the component alone adopts the change, leaves its
siblings untouched, and leaves both the composite's saved curation and its
curated tool set unchanged, whether the component gained or dropped a tool.
Updating the composite updates pending components first and adopts the entry's
membership, overrides, and prefixes only after all of them succeed, preserving
each surviving component's `url` and `disabled`; a failing component is reported
individually, stops neither its siblings nor a later retry, and leaves the
composite's curation unadopted. Composite deployment status follows the worst
enabled component and a disabled component contributes nothing. A composite
catalog entry reports no update state throughout, while the catalog list still
highlights it when one of its deployments is pending.

**Migrating an existing composite.** A composite created before the change
reads, deploys, configures, and connects unchanged, then persists the slim shape
on its next write with its per-deployment URL preserved by the upgrade backfill.
Rotating a component's static OAuth credential takes effect with no update, and
rotating it alongside that component's configuration surfaces as an ordinary
pending update on the component server.

## References

None.
