# 2026-09-22: OpenAPI-backed MCP catalog entries

- **Authors:** @calvinmclean
- **Created:** 2026-09-22

## Summary

Let catalog authors upload an OpenAPI specification or provide its URL to create
an MCP catalog entry. Run a reusable FastMCP container that converts the API to
MCP using FastMCP's OpenAPI integration.
The wrapper source and container build live in `mcp-images`.
Users configure API keys and compose the entry into a vMCP. OAuth is not supported in
the initial implementation.

Configuration allows users to enable FastMCP Tool Search and, only when search
is enabled, supply basic rules that disable tools inside FastMCP. Without Tool
Search, tool selection belongs to vMCP.

## Related issues

- [obot#5555](https://github.com/obot-platform/obot/issues/5555) — expose REST
  APIs through Obot catalogs and the MCP gateway.
- [obot#1247](https://github.com/obot-platform/obot/issues/1247) — historical
  context on credential refresh in earlier OpenAPI tools; this remains closed.

## Related ODPs

- [Virtual MCPs](../2026-09-01-virtual-mcps/README.md) — extends the available
  catalog component types and follows its connection, configuration, and
  snapshot/upgrade model.

## Problem and motivation

Services often publish OpenAPI specifications but do not serve MCP. Users should
be able to connect them without building a custom integration. FastMCP already
provides OpenAPI conversion and Tool Search; a configurable container lets Obot
reuse these features through its existing hosted-MCP paths.

## Goals

- Create catalog entries from uploaded or linked specifications.
- Use a shared container image, configured per API, with no per-API code generation.
- Support unauthenticated APIs, header-based API keys, and vMCP composition.
- Make Tool Search configurable and allow FastMCP exclusions only in search mode.
- Keep running entries stable until an explicit upgrade.

## Non-goals

OAuth, query-parameter or cookie authentication, custom search/HTTP execution
engines, or full OpenAPI compatibility in the first release.

## Context and constraints

FastMCP's OpenAPI integration generates tools and their input schemas and
executes HTTP requests. Its BM25 search transform can replace the direct tool
listing with search and invocation tools. The wrapper supplies per-request
credentials through the HTTP client used by those tools.

The production image must pin and test its dependencies rather than assume
every valid specification is supported.

## Proposed design

### Creating catalog entries

- **UI:** select **OpenAPI** as the catalog entry type. Upload an OpenAPI file or
  provide a specification URL. These are mutually exclusive sources.
- **API destination:** show the base URL resolved from the specification and
  allow an explicit `baseURL` override. Require an override if the specification
  has no usable server URL. The override controls API requests, not where Obot
  fetches the specification, and applies consistently to generated operations.
- **Options:** define sensitive API-key header inputs by name,
  Tool Search, and exclusions when search is enabled. Preview generated tools
  and report unsupported features before saving the entry.
- **GitOps:** add a catalog entry with runtime `openapi` and equivalent settings.
  Proposed source fields are either an inline specification document or a URL;
  inline content is the GitOps equivalent of an uploaded file. Include the
  optional `baseURL`, header definitions, Tool Search, and exclusions in the
  definition, but never secret values. Exact field names remain for review.

Both paths use the same import validation and store the actual specification
internally in Obot, not just its URL or declared version. The `openapi` runtime
is backed by the existing container deployment infrastructure, not a new hosting
backend. Authors do not need to configure a container image or command.

### Container setup

Keep the Python wrapper, dependencies, tests, and Dockerfile in `mcp-images` so
the image can be built directly from that repository. Package it in one reusable
image. Each deployment receives the specification, API base URL, allowed
credential header names, Tool Search setting, and any permitted exclusion rules. API credentials
arrive separately on each request, not in container environment variables.
FastMCP exposes Streamable HTTP for Obot to connect to through its existing
container deployment infrastructure.

```text
MCP client → Obot gateway / vMCP → FastMCP container → REST API
```

Obot owns catalog setup, deployment, connections, and gateway access controls.
FastMCP owns OpenAPI conversion, tool schemas, search, and HTTP request execution.
No new protocol translation handler is needed inside Obot.

### Updates and refresh

Obot stores schema content internally for both catalog entries and deployed
vMCP snapshots. API version fields and source URLs are not reliable change
indicators; use the stored content for normal drift detection and upgrade review.

- **UI-managed entries:** replace an uploaded file or use Refresh to fetch a
  linked specification again. Validate and save the schema content in Obot.
- **GitOps:** every catalog sync imports the schema, fetching linked URLs again
  even when the Git revision, URL, and declared API version are unchanged.
  Inline schemas are also imported on every sync. No refresh marker is needed.
  Git-managed definitions remain read-only in the UI.
- **Failures and unchanged content:** report fetch or validation errors and
  retain the last working schema. Identical content creates no new drift.
  Refresh preserves an explicit base URL override.
- **Drift review:** normal drift detection compares the latest stored catalog
  schema with the deployed vMCP component snapshot. Show a diff of the actual
  API schema in the UI, not just a URL, version, digest, or generated tool list.
  Include configuration changes and flag destination or credential-header
  changes so users can decide whether to update the MCP server.

### Tool Search and filtering

| Mode | What FastMCP lists | Where tools are restricted |
| --- | --- | --- |
| Search disabled | Generated API tools | vMCP tool selection; FastMCP exclusion rules are not allowed |
| Search enabled | search_tools and call_tool | FastMCP exclusions restrict underlying operations; vMCP controls access to the exposed search/call tools |

Enable search using FastMCP's BM25 search transform. It returns matching tool
definitions and input schemas, and call_tool invokes a discovered tool. Use the
library's implementation rather than adding custom general tools.

Support exclusion rules only, using FastMCP's OpenAPI route mapping. Rules match
HTTP methods, regular expressions against OpenAPI paths, and operation tags.
Do not support include rules or user-provided Python. Apply exclusions when creating
the OpenAPI tools, before applying Tool Search.

The proposed configuration schema is:

```yaml
toolSearch: true
exclude:
  - method: DELETE
  - pathPattern: "^/admin/"
  - tag: internal
```

`exclude` is a list of rules with only these optional fields:

- `method`: an uppercase HTTP method.
- `pathPattern`: a regular expression matched against the OpenAPI path
  template, not the full URL or substituted parameter values.
- `tag`: an exact, case-sensitive OpenAPI operation tag name. An operation
  matches if it has that tag.

Each rule must contain at least one nonempty string field. When multiple fields
are present, all must match. An operation is excluded if any rule matches; use
separate entries for alternatives rather than lists within a rule. Reject
unknown fields, non-string or empty values, and invalid regular expressions.
The configuration above excludes all DELETE operations
as well as operations whose paths start with `/admin/` or have the `internal` tag.

To exclude only `POST /users`, combine the method and an exact-path regex in
one rule:

```yaml
toolSearch: true
exclude:
  - method: POST
    pathPattern: "^/users$"
```

This leaves `GET /users` and POST operations on other paths available.

Obot rejects exclusions when Tool Search is off. The container consumes saved
settings without repeating that check, but must not ignore exclusions or expose
blocked operations. The UI offers exclusions only in search mode; disabling
search requires clearing the rules and reviewing direct tools.

This distinction matters because vMCP sees individual operations without search,
but sees only the search and invocation tools with search enabled. It cannot
restrict the operations behind call_tool using ordinary tool-name selection.
FastMCP exclusions therefore define the operations available to that configured
server. They are not a new per-user vMCP permission system. Users needing
different underlying operation sets need separately scoped configurations or
deployments; incompatible rule sets must not share one FastMCP instance.

Tool Search hides direct tools from listing but keeps them callable. Excluded
operations must instead be unavailable through search, call_tool, and direct
calls by name. Verify this behavior against the pinned FastMCP release.

### Authentication and multi-user deployments

- **Credential ownership:** the catalog defines header inputs. At vMCP creation,
  the author chooses `fixed` or `userAllowed` for each required input. Obot
  already sends user-allowed values on MCP requests and applies configured
  prefixes, such as `Bearer ` for an `Authorization` header. Supporting fixed
  values for this hosted container requires Obot to send them on MCP requests
  as well. Neither kind of value goes into container environment variables.
- **Header forwarding (new wrapper behavior):** the wrapper reads only declared
  credential headers from each MCP request and sends the same names and values
  to the target REST API. It does not add a prefix or transform values. Direct
  tools and call_tool use the same forwarding path.
- **Isolation:** never mutate shared HTTP-client headers or reuse another
  request's credential. Reject missing required keys. Do not forward arbitrary
  client headers or Obot's login token. Send API credentials only to the
  configured destination, never to specification sources or unrelated redirects.
  Keep secrets out of specifications, tool arguments, descriptions, results,
  and logs.
- **Shared deployments:** user-allowed headers permit a shared vMCP component;
  user-allowed non-header inputs or forceSingleUser require dedicated runtimes.
  Specification, allowed credential header names, search, and exclusions remain fixed for a
  shared component. Different runtime settings need separate components or
  deployments.
- **Future OAuth:** not supported initially. Obot's managed MCP OAuth flow is
  currently remote-only. Per-request credentials prepare for Obot-owned OAuth
  to the target API: Obot would obtain, store, and refresh access tokens and
  supply them through this header path, leaving the wrapper without OAuth state.
  That flow requires separate design and implementation; accepting bearer
  credentials alone does not provide OAuth login or refresh.

### Failures and operations

Use the existing hosted-MCP lifecycle for startup, health, restart, and shutdown.
On schema or configuration errors, keep the container running and log a safe
reason. Serve unaffected operations only if access cannot widen. Otherwise,
fail readiness and MCP requests with safe errors, keep liveness healthy, and
show the reason in vMCP status. Keep secrets and specification contents out of
diagnostics. Bound parsing, HTTP requests, concurrency, and response sizes;
return useful tool errors for upstream failures.
Apply network policy to specification/reference loading and API requests,
including redirects. Containerization does not remove these requirements.

Keep existing gateway auditing and secret redaction. In search mode, ordinary
audit records identify call_tool; confirm how to record its target operation and
how hooks or approvals inspect that target before enabling sensitive operations.
Confirm FastMCP's session behavior works with existing proxying and deployment
routing rather than treating a container as a solution to session state.

## Alternatives considered

- **Build our own Go-based conversion layer:** gives us direct control over
  OpenAPI parsing, tool generation, and HTTP execution, but requires maintaining
  that conversion and search behavior ourselves. The proposed design reuses
  FastMCP's existing implementations which are robust and industry-tested.
- **Handle OpenAPI APIs directly in Obot, similar to remote MCP servers:** keeps
  execution inside Obot, but REST APIs cannot use the remote MCP proxy path
  unchanged. Obot would need to own MCP-to-HTTP translation. The proposed design
  keeps that work in a reusable wrapper hosted through the container runtime.

## Trade-offs

This reuses FastMCP and Obot's container infrastructure, but adds Python
dependencies and workload overhead.

Search reduces the advertised tool list but moves operation filtering into
container configuration. Direct mode keeps familiar vMCP tool selection and
avoids a second filtering configuration.

## Rollout and migration

Introduce the container image and catalog creation flow without changing existing
entries. Validate unauthenticated APIs, then API keys. No automatic
migration is needed. Pin image and specification revisions and use explicit
upgrades. Reverting a deployment must restore its filtering configuration too;
never fall back to an unfiltered server after a configuration error.

## Testing and validation

- Verify OpenAPI entry creation through the UI and equivalent GitOps imports,
  source validation, and base URL overrides.
- Cover replacement uploads, URL refresh, unchanged content, and fetch failures.
  Verify every GitOps sync imports the schema, including changes at the same URL
  with unchanged Git and API versions.
- Confirm drift displays the actual schema diff, existing vMCPs stay pinned
  until upgrade, and restarts use stored schemas without fetching the source.
- Without search, verify vMCP enforces direct tool restrictions and FastMCP
  exclusions are rejected. With search, verify excluded operations cannot be
  found or called through either invocation path.
- Inject conversion and configuration errors; verify the process stays up, Obot
  sees safe errors, and no blocked operation becomes available.
- Test concurrent users with different user-allowed keys through one shared
  container in both modes. Verify each API request uses the correct credential
  and missing keys cannot reuse another user's key. Also verify fixed keys reach
  the API without appearing in container environment variables.
- Cover Obot's existing prefix behavior, including headers without a prefix
  and avoiding duplicate prefixes for values that already contain one.
- Use local APIs for repeatable tests and a public API for optional live smoke
  tests.

## References

- [FastMCP OpenAPI](https://gofastmcp.com/integrations/openapi) — conversion and
  route exclusion rules.
- [FastMCP Tool Search](https://gofastmcp.com/servers/transforms/tool-search) —
  discovery and invocation.
