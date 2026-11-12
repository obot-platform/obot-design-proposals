# 2026-11-09: Agent identities for headless access

- **Authors:** @thedadams
- **Created:** 2026-11-09

## Summary

Add organization-scoped Agents as durable service-account identities. Admins
create agents, issue agent-owned API keys, and grant access through vMCP profiles,
model access policies, and skill access rules. vMCP profiles supply shared
configuration and upstream OAuth authorization for agents,
so connections never require an interactive user. Agent keys default to all of
the agent's grants; optional key restrictions can only narrow access.

## Related issues

- [field-issues#75](https://github.com/obot-platform/field-issues/issues/75):
  delivers independent agent identity, credentials, auditing, and access to MCP,
  the LLM Gateway, and Skills; delegation remains a follow-up.

## Related ODPs

- Extends [Virtual MCPs](../2026-09-01-virtual-mcps/README.md) with agent subjects
  and profile-owned configuration and OAuth grants.

## Problem and motivation

Automation currently depends on user identities and user-owned credentials.
Agents need stable identities and access policies that survive key rotation and
changes to the humans managing them. Their upstream configuration must be
prepared by administrators because no user is present during execution.

## Goals

- Admin-managed agents with independent, revocable credentials and audited activity.
- Existing additive vMCP permissions, with deterministic agent configuration.
- Model and skill grants through existing policies/rules, with optional key restrictions.
- API/UI readiness reporting and actionable failures without authentication prompts.

## Non-goals

Agent groups, personal vMCPs, agent hosting, user invocation policies, acting on
behalf of users, per-user credential delegation, device access, and a Terraform
provider. Admin APIs support automation.

## Context and constraints

Today API keys and vMCP instances belong to users. Profiles combine permissions
but contain no configuration. Fixed values belong to the vMCP; user inputs belong
to its instance. Catalog-static values and Secret bindings cannot be overridden
by vMCP configuration. Shared runtimes permit per-caller headers, but differing
process configuration requires isolated runtimes.

LLM Gateway profiles (`ModelAccessPolicy`) grant models and carry budgets and
guardrail policies. `SkillAccessRule` grants individual skills, repositories, or
all skills. API-key service permissions are additional gates, not resource grants.

## Proposed design

### Identity, credentials, and lifecycle

Store `Agent` in Gateway types alongside other identities, with a stable ID,
display metadata, ownership metadata, creator attribution, and active/disabled/
deleted lifecycle state. Owners are administrative metadata, not the source of
agent privileges. Agents have no user roles, group memberships, or interactive
login. Changes to an owner do not change agent identity or grants.

Extend API-key ownership to distinguish users from agents, enforcing exactly one
owner. Reuse existing secret hashing, one-time disclosure, optional expiration,
rotation through overlapping keys, revocation, and last-used tracking. Preserve
existing user-key formats and behavior; agent credentials must identify their
owner kind unambiguously. A key authenticates one agent and defaults to all access
granted to that agent. For new agent keys, omitted restrictions default to
`MCPServerIDs: ["*"]`, `CanAccessLLMProxy: true`, and `CanAccessSkills: true`.
Admins may restrict vMCP IDs or disable either service; explicit empty MCP scopes
and false flags must be preserved. Existing user-key defaults remain unchanged.

Effective access is the intersection of the agent's current policy grants and
the key's restrictions, never a snapshot of grants at key creation. Grant changes
apply to existing keys; `*` permits all vMCPs granted to the agent. Service flags
alone grant no models or skills: model access policies and skill access rules
remain authoritative. LLM/Skills access requires no vMCP profile or MCP scope.
Agent keys grant no general administrative API or device access. Authentication,
authorization, usage accounting, and audit paths must support agent callers
without loading them as users or inheriting the creating admin's permissions.

Reuse the user lifecycle outbox/event pattern: persist lifecycle changes with a
durable event, then deliver idempotent v1 Agent change/delete objects for
controllers. Authentication checks current agent/key state on subsequent
requests, including cache hits and internal authenticated requests. Once an agent
is disabled/deleted or a key is revoked, subsequent requests are rejected even
if controllers have not yet removed its connections and credentials. Disablement
preserves assignments. Deletion revokes keys, removes explicit agent subjects
from vMCP profiles, model access policies, and skill access rules, and cleans up
agent connections and their credentials, while retaining audit history and
credentials still owned by shared profiles.

Identify each caller by its kind (`user` or `agent`) and stable record ID. Carry
both through authentication, vMCP/component instance ownership, credential
contexts, internal loopback tokens, and session/cache keys. Never interpret an
agent ID as a user ID. Reuse the vMCP instance flow with one canonical connection
per agent/vMCP; different keys belonging to that agent use the same connection.

### Profiles and selection

Add explicit agent subjects and the same three wildcard forms to vMCP profiles,
model access policies, and skill access rules:

| Subject | Matches |
| --- | --- |
| `subjects:*` | All users and agents; existing `selector:*` representation |
| `users:*` | All users |
| `agents:*` | All agents |
| Explicit user or agent | Only that typed identity |

Model access policies and skill access rules combine grants from every matching
policy/rule, as they do for users. Agents can receive specific model, skill, or
repository grants, or wildcard resource grants. Apply the matching LLM profiles'
budgets and guardrail policies using existing semantics. Agents do not match
user-only subjects or groups. The configuration and OAuth selection rules below
apply only to vMCP profiles.

Per vMCP, allow either one `subjects:*` profile, or at most one `users:*` and one
`agents:*` profile. An agent may be listed explicitly in only one profile. Enforce
these rules in API and catalog validation, including concurrent updates.

Permissions remain the union of matching profiles. Prefer configuration from the
explicitly matching agent profile. For each missing required value, fall back to
the wildcard profile granting agent access (`agents:*`, or `subjects:*` when
present). Optional values do not fall back. Without an explicit assignment, use
the wildcard profile's configuration directly.

Select OAuth grants per component: use the explicit profile's grant when present,
otherwise fall back to the wildcard profile's grant. A revoked or unrefreshable
explicit grant fails; it must not trigger fallback to a different upstream account.

Only profiles granting agents access may contain configuration or OAuth grants.
Values are profile-wide and consumed only by agents, even on mixed user/agent
profiles. A profile may configure any vMCP component; supplying values
never grants access. For example, if a wildcard grants A and an explicit profile
grants B, the agent may use both. Required values and OAuth grants missing from
the explicit profile can come from the wildcard profile. Removing an explicit
assignment falls back to any remaining wildcard access and configuration; it is
not revocation.

### Configuration and OAuth

Give profiles immutable IDs so rename/reorder operations preserve credentials.
Store secrets in the existing credential store, scoped by vMCP, profile, and
component ID; manifests contain references, not secret values. Publish credential
revisions consistently with configuration changes and reconcile instance copies.

Profiles supply required user-allowed inputs, using the precedence above.
Optional inputs may remain unset. Normal vMCP-fixed values cannot be overriden
by an agent profile. Retain existing schema, URL, and Secret-binding validation.

Admins may complete OAuth separately for each component on an agent-capable
profile. Store the resulting access/refresh tokens as profile-owned grants shared
by agents resolving to that grant, including through fallback. Static OAuth client
credentials supplied by the catalog remain authoritative; they are distinct from
these authorization grants.
Bind callbacks to the initiating admin and stable profile/component/target, and
reject completion after deletion or incompatible target changes. Refresh shared
tokens safely across concurrent callers; failure requires admin reauthorization.
Grants survive changes to the admin who created them, subject to upstream validity.

### API, UI, and failure behavior

Add admin Agent CRUD, disable/enable, and key-management APIs and corresponding
UI. Default agent-key creation to all agent grants, with optional vMCP restrictions
and LLM Gateway/Skills toggles. Extend model access policy and skill access rule
editors with explicit agent selection and the three wildcard forms. Extend vMCP
profile editing with typed subject selection, configuration, OAuth setup/reset,
and readiness. Use existing API conventions; profile-specific
operations address immutable profile IDs. Agents cannot mutate configuration,
retrieve stored secrets, manage keys, or initiate interactive authorization.

Allow incomplete profiles to be saved. The API exposes readiness and structured
reasons with component ID and missing field or OAuth requirement, never secret
values. The UI displays these reasons and admin repair actions. Expose effective
agent/vMCP readiness as well as profile setup status: additive grants can require
components outside the explicit profile's own grants. Evaluate readiness after
wildcard fallback. Recheck after access, configuration, component, and credential
changes, and enforce current state at
connection/request time rather than trusting stale displayed status.

Check only components enabled for the agent. Any enabled component missing
required setup blocks the entire connection; do not silently offer fewer tools.

| Condition | Response |
| --- | --- |
| Invalid/missing credential | Existing authentication failure behavior |
| Authenticated agent lacks access | `403 Forbidden` |
| Required configuration missing | `409 Conflict`, `agent_configuration_required` |
| Required upstream authorization unavailable | `409 Conflict`, `agent_oauth_required` |

Agent setup failures include safe component diagnostics and no `WWW-Authenticate`
header, redirect, or interactive challenge ticket. Apply this at setup and to
upstream authorization failures during requests, including composite loopbacks.
An already-started response uses the protocol's error path without prompting.
Keep transient deployment/upstream failures distinct from missing setup.

Audit agent lifecycle, key, profile, model/skill policy, and OAuth changes with
the acting admin. Attribute MCP, LLM Gateway, and Skills activity to the stable
agent and authenticating key. For MCP, also record the vMCP/component and contributing
configuration/OAuth profiles, including fallback. Retain attribution after
deletion without logging secrets.

### Future delegation

Keep the authenticated actor distinct from any future represented user in
identity and audit contracts. Level one has an agent actor and no represented
user. Later agent profiles can restrict which users an agent may represent;
delegation proof, user credential selection, and invocation policies require a
separate ODP. Do not treat the creating admin as an implicit represented user.

## Alternatives considered

- Special users or internal storage service accounts: conflate different identity,
  lifecycle, and privilege models.
- v1 Agent storage: convenient controller watches, but separates identity/key
  lifecycle persistence; Gateway plus existing lifecycle events fits better.
- Per-agent configuration or arbitrary profile ordering: adds complexity;
  explicit precedence with one wildcard fallback provides deterministic sharing.
- `401` or challenged `403` for missing setup: initiates an unusable interactive
  flow. `409` distinguishes setup state from access denial.

## Trade-offs

Profile-wide credentials simplify setup but share an upstream account and failure
domain. Distinct upstream identities require distinct profiles. Dedicated
runtimes increase resource use. Additive permissions mean explicit profiles can
override configuration but cannot narrow wildcard grants. Wildcard credentials
may serve explicitly assigned agents when their profiles omit required setup.

## Risks and open questions

No unresolved product decisions. Implementation must verify shared OAuth refresh,
credential/session isolation, and lifecycle-event retry behavior. Preserve
upstream target binding when configuration changes so
tokens cannot be reused against a different destination.

## Rollout and migration

Add identity/key schema, typed connection ownership, profile IDs/credentials, and
agent-aware matching/enforcement for vMCP, model, and skill grants before enabling
agent creation and policy editing. Existing user records and credentials retain
their meaning. No wildcard migration:
existing subject `*` selectors in these three policy systems also match agents;
missing required vMCP setup still blocks connections. Existing multiple vMCP
`subjects:*` profiles may retain permission behavior until edited; require
disambiguation before adding wildcard
configuration, and fail closed if agent configuration selection is ambiguous.
Do not expand wildcard semantics in unrelated policy systems.

Older versions do not understand these identities or policies: rollback requires
disabling agent access and restoring compatible profile definitions, not merely
reverting the binary. Retain agent/audit data rather than destructively undoing schema changes.

## Testing and validation

- Typed identity isolation; default access to all agent grants, optional key
  restrictions, rotation, expiry, revocation, and disable/delete across replicas,
  cached sessions, and signed loopback requests.
- Omitted versus explicitly empty/false key restrictions, unchanged user-key
  defaults, and grant changes taking effect for existing keys.
- Agent and wildcard subject matching across all three policy systems; additive
  model/skill grants, LLM budgets/guardrails, service flags without resource grants,
  keys without MCP scopes, service restrictions, and agent usage/audit attribution.
- Wildcard exclusivity, duplicate explicit assignment, additive grants, explicit
  configuration/OAuth precedence, required-value and missing-grant fallback from
  either wildcard form, failure of invalid explicit grants without fallback,
  mixed profiles, and assignment-removal fallback.
- Required versus optional inputs, catalog immutability, fixed-value overrides,
  disabled-component exclusion, dedicated runtime selection, and secret isolation.
- Incomplete saves and API/UI diagnostics; whole-connection failure; OAuth
  callback binding, refresh contention, revocation, and mid-session failures
  without authentication challenges.
- Lifecycle delivery retries/cleanup, profile rename/delete and credential
  cleanup, retained audit attribution, existing user behavior, and legacy `*`
  compatibility. Record the shipped design in an implementation ADR.

## References

- Obot: `pkg/vmcp`, `pkg/mcp/vmcp.go`, `pkg/gateway/client/lifecycle.go`,
  `pkg/gateway/server/apikey_auth.go`, `pkg/api/handlers/mcpgateway`, and the vMCP
  instance/component controllers are the principal MCP implementation boundaries.
  LLM Gateway and Skills authentication, authorization, accounting, and audit
  paths must also accept agent callers.
