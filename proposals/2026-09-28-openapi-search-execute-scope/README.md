# 2026-09-28: Move OpenAPI search and execute to vMCPs

- **Authors:** @calvinmclean
- **Created:** 2026-09-28

## Summary

OpenAPI-backed catalog entries will expose generated operations as ordinary MCP
tools without an option for search/execute. Search and generic execute will be
a top-level vMCP feature, released in the same version as OpenAPI support, which
may or may not require its own ODP. vMCP setup will provide more flexibility and
control for users without needing regex rules or knowledge of OpenAPI routes.

## Related issues

- [obot#5555](https://github.com/obot-platform/obot/issues/5555) — OpenAPI-backed
  catalog entries.
- [obot#8065](https://github.com/obot-platform/obot/issues/8065) — vMCP-level
  tool search and invocation planned for the same release.

## Related ODPs

- [OpenAPI-backed MCP catalog entries](../2026-09-22-openapi-mcp/README.md) —
  changes its planned search and invocation scope.
- [Virtual MCPs](../2026-09-01-virtual-mcps/README.md) — builds on its component
  tool selection and profile controls.

## Decision

The OpenAPI FastMCP container will not enable Tool Search or expose
`search_tools` and `call_tool`.

During vMCP setup, users can select generated tools to exclude from that
component's tool list, using the vMCP's tool controls instead of writing
route-matching rules.

## Consequences

The release must include vMCP search and execute for large tool sets. Tool
exclusions are visible choices in vMCP setup, with no separate FastMCP rule
syntax. This scope change precedes the initial OpenAPI release, so no deployed
entries need migration.

## Validation

- Confirm generated operations are listed and callable, while `search_tools`
  and `call_tool` are absent.
- Verify a tool excluded during vMCP setup is absent from direct listings and
  search results and cannot be invoked through either path
- Verify generated tools still use the correct per-request API credentials and
  vMCP search and execute work with them before the joint release.
