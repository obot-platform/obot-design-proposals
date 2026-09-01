# 2026-08-28: Opt-in product telemetry

- **Authors:** @calvinmclean
- **Created:** 2026-08-28

## Summary

Add opt-in, installation-level product telemetry to understand Obot adoption and use of built-in capabilities. After an Owner opts in, Obot will send aggregate telemetry to upgrade-server daily without affecting the existing upgrade check.

Consent is stored as a set of stable telemetry identifiers. New identifiers introduced later are not authorized by an earlier opt-in.

## Related issues

- [obot-platform/obot#7693: Add opt-in product telemetry](https://github.com/obot-platform/obot/issues/7693)

## Related ODPs

None.

## Problem and motivation

Obot lacks aggregate adoption data for prioritizing features and evaluating the compatibility impact of changes such as the recent MCP catalog overhaul. This proposal adds narrowly scoped telemetry without collecting customer content (audit logs, custom MCP entries, MCP configurations, etc.) or system-level configurations that might contain customer details.

## Goals

- Collect the initial aggregate metrics daily from opted-in installations.
- Preserve existing upgrade-check behavior and normal Obot operation.
- Require explicit consent for each telemetry identifier.
- Support compatible evolution of consent identifiers and payload fields.

### Initial telemetry scope

The initial release defines one consent identifier per telemetry type:

- `TotalUsers`: total users.
- `ActiveUsers`: users active during the previous full UTC day.
- `DeployedMCPServers`: total deployed MCP servers.
- `BuiltInMCPServerUsage`: stable name, ID, deployment count, and aggregate user count for each built-in catalog server.
- `CustomMCPServerEntryCount`: total non-built-in MCP catalog entries.
- `AuthProviderType`: configured authentication-provider type.
- `MCPAuditLogCount`: MCP audit-log records created during the previous full UTC day.
- `LLMAuditLogCount`: LLM audit-log records created during the previous full UTC day.
- `SentryScanCount`: Sentry device scans received during the previous full UTC day.
- `SentryEnforcementEventCount`: Sentry enforcement-decision records created during the previous full UTC day.
- `ManagedSkillCount`: total skills managed from configured skill repositories at collection time.

## Non-goals

- Collecting user-level activity, customer content, credentials, configuration values, URLs, exact errors, or other identifying data.
- Reporting the identity or configuration of custom MCP servers.
- Defining an exhaustive long-term telemetry schema.
- Providing fine-grained consent choices or controls to view or change consent after the initial choice. Changing recorded consent initially requires direct database modification.

## Context and constraints

Obot already stores an installation ID through `pkg/upgrade.GetInstallationID` and performs a daily upgrade check from `pkg/api/handlers/version.go`. Telemetry will reuse the installation ID and upgrade-server relationship but remain independent of the upgrade check.

Existing data sources include:

- `UserCount`, which excludes deleted users and the bootstrap account.
- `ActiveUsersByDate`, which excludes bootstrap, anonymous, empty, internal, and deleted users.
- Aggregate user counts on built-in catalog entries.
- Separately persisted MCP and LLM audit logs.

Telemetry must send only aggregate installation-level values, document every collected field and its cadence, and evolve through additive optional fields. An absent consent identifier never authorizes collection.

## Proposed design

### Consent

- Show Owners an explicit all-or-nothing choice during login until one records a decision. Dismissing the modal is not consent.
- Explain the collection and link to its complete public documentation.
- Store consent in the installation-level `product_telemetry_consent` property as a JSON list. A missing property is undecided, `[]` is opted out, and opt-in stores every identifier in **Initial telemetry scope**.
- Do not expose the recorded choice or allow changes through the initial UI or API.

### Collection and transport

- In an independent PR, move upgrade-check lifecycle and state into `pkg/upgrade.Checker`; `VersionHandler` will read its status through a small interface. This is not strictly necessary, but is an opportunity for clearer organization that was identified.
- Put telemetry collection, transport, and scheduling in `pkg/producttelemetry`. Start its context-bound job during `pkg/services.New`; it runs immediately and then daily at a fixed time, reading consent on each run.
- Reuse `pkg/upgrade` only for the installation ID. Define payload types in `apiclient/types`.
- Map each consent enum to its collector and payload fields, then send only authorized fields in a JSON `POST` to upgrade-server.

### Payload

Reports are identified by installation ID and the UTC date of `reportedAt`. A newer `reportedAt` replaces older data for that date. Optional scalar and count fields use Go pointers: `null` means unavailable, while `0` means a measured zero.

```json
{
  "installationID": "7d7d83d8-2af0-4da8-ae2d-102d8eaa70be",
  "reportedAt": "2026-08-31T00:04:12Z",
  "metrics": {
    "totalUsers": 42,
    "activeUsers": null,
    "deployedMCPServers": 0,
    "customMCPServerEntryCount": 4,
    "builtInMCPServers": [
      {
        "id": "github",
        "name": "GitHub",
        "deploymentCount": 2,
        "userCount": 7
      }
    ],
    "authProviderType": "github",
    "mcpAuditLogCount": 0,
    "llmAuditLogCount": null,
    "sentryScanCount": 14,
    "sentryEnforcementEventCount": 3,
    "managedSkillCount": 27
  }
}
```

### Failure behavior

- Undecided, opted-out, or wholly unrecognized consent produces no request.
- Telemetry initialization, collection, and delivery failures are logged but never block startup or normal operation.
- Failed delivery uses exponential backoff with the same installation ID and `reportedAt`.

## Alternatives considered

### Status quo

Collect nothing. This avoids new consent and collection mechanisms but leaves maintainers unable to quantify adoption or compatibility risk. Opt-out preserves this behavior.

### gRPC

Use gRPC for a structured, evolvable contract. It adds dependencies and build complexity without a need for streaming or high throughput; one small daily JSON request fits the existing HTTP integration.

## Trade-offs

- JSON is simple and consistent with the current integration, at the cost of compile-time contract enforcement and wire efficiency.
- Identifier-based consent is more complex than a boolean but prevents new telemetry from inheriting prior consent and leaves possibility for future fine-grained options.

## Risks and open questions

- **User trust:** Mitigate discomfort with explicit opt-in, plain-language disclosure, and complete public documentation. The initial release does not provide UI or API controls to review or change consent.

## Rollout and migration

- Deploy the receiving upgrade-server capability before releasing the Obot sender.
- Existing installations begin undecided and send nothing until an Owner opts in.
- Monitor request acceptance and delivery failures as installations upgrade.

## Testing and validation

- Verify consent states, Owner-only decisions, repeated prompting while undecided, and no UI or API for later review or changes.
- Verify only collectors for recognized, consented identifiers run.
- Verify previous-full-day UTC boundaries, report-time totals, and existing count definitions.
- Verify custom MCP servers and prohibited data never enter a payload.
- Verify `null` versus measured zero serialization.
- Verify telemetry failures do not affect startup, normal operation, or upgrade checks.
- Verify request compatibility, retry identity, and newer-report replacement.
- Add an end-to-end contract test with a representative authorized payload.

## References

- [Obot issue #7693](https://github.com/obot-platform/obot/issues/7693)
- Existing Obot upgrade client: `pkg/upgrade/client.go`
- Existing Obot upgrade scheduler: `pkg/api/handlers/version.go`
- Existing gateway user metrics: `pkg/gateway/client/user.go` and `pkg/gateway/client/apiactivity.go`
