# 2026-08-14: Support MCP Specification Version 2026-07-28

- **Authors:** @thedadams
- **Created:** 2026-08-14

## Summary

The latest MCP specification was released with many larger changes. We would like
to support the latest specification. In order to do so, I am proposing that we
replace Nanobot with the official [Go MCP SDK] in Obot's MCP clients, gateway,
and hosted-server wrapper. Move Obot-specific hooks and audit logging into Obot
and create a new `obot-platform/mmcp` (`mmcp` stands for Multi-MCP) project for
hosted server images and composite MCP servers. This adds the complete 2026-07-28
MCP specification, including stateless mode, while retaining 2025-11-25 compatibility.

## Related issues

- [obot-platform/obot#7309](https://github.com/obot-platform/obot/issues/7309) —
  support the 2026-07-28 MCP specification.

## Related ODPs

None.

## Problem and motivation

Obot adopted Nanobot before an official Go MCP SDK existed. Nanobot now powers
MCP clients used in our API, the MCP gateway, and the `stdio-wrapper` image used
by hosted servers. Supporting the 2026-07-28 specification by extending Nanobot
would leave Obot maintaining a protocol implementation that is now available
upstream, along with Nanobot functionality Obot does not use.

## Goals

- Support the complete 2026-07-28 specification, including stateless mode.
- Retain 2025-11-25 support and existing hooks, audit logs, OAuth, tunnels,
  composite servers, and configured network blocking behavior.
- Remove Nanobot from API clients, the gateway, and hosted server images.

## Non-goals

- Add unrelated user-facing features or change public APIs, configuration,
  persistence, or deployment workflows.
- Guarantee older specification versions. They will be supported as needed.

The move to using the Go SDK also enables transparent OAuth discovery through
tunnels. That is, oauth-protect-resource and oauth-server-metadata endpoints
will be contacted through the tunnel. This is a consequence of the migration
rather than a separate feature.

## Context and constraints

The Go SDK does not provide Obot's exact hook and audit-log behavior, so that
code must move from Nanobot into Obot without changing its observable behavior.
Obot must also preserve its configured blocking of loopback, private, and
link-local addresses. The migration will use Go SDK v1.7.0.

## Proposed design

Use the Go SDK for MCP protocol handling in all three current Nanobot roles:

1. Construct Obot API clients with the SDK.
2. Use the SDK inside the MCP gateway for non-composite servers, while Obot
   continues to own hooks, audit logging, OAuth, tunnels, network blocking,
   and composition.
3. Create the proposed `obot-platform/mmcp` project, replace the
   Nanobot-based `stdio-wrapper` with a Go SDK-based wrapper for hosted servers,
   and replace that last bit of Nanobot proxy code in Obot used for composite
   MCP servers.

The SDK owns protocol negotiation between 2025-11-25 and 2026-07-28 clients.
Compatibility workarounds will be added when real servers or OAuth flows do not
conform to the specifications.

## Alternatives considered

### Update Nanobot

Updating Nanobot would preserve the current integration, but Obot would remain
responsible for MCP protocol changes and unused Nanobot functionality. Using
the official SDK and retaining only Obot-specific behavior is expected to be
simpler. Keeping the status quo was rejected because it cannot provide the
required specification or stateless-mode support.

## Trade-offs

The official SDK removes protocol maintenance from Obot and provides one MCP
implementation across all paths. In exchange, Obot must extract and own its
custom behavior.

## Risks and open questions

- Nonconforming servers or OAuth flows may require compatibility workarounds.
- The final name of `obot-platform/mmcp` must be confirmed.

## Rollout and migration

Migrate and manually test one path at a time:

1. API-created clients (already merged and on `main`).
2. Gateway non-composite servers.
3. Gateway composite servers.
4. The hosted-server `stdio-wrapper`.

## Testing and validation

Rely on the Go SDK's conformance tests for protocol behavior and existing unit
tests for Obot-owned behavior. Manually test API clients, both gateway server
types, the hosted-server wrapper, OAuth, tunnels, hooks, and audit logs against
2025-11-25 and 2026-07-28.

## References

- [MCP 2026-07-28 specification]

[Go MCP SDK]: https://github.com/modelcontextprotocol/go-sdk
[MCP 2026-07-28 specification]: https://modelcontextprotocol.io/specification/2026-07-28
