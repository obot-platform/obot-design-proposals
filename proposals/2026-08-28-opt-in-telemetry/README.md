# 2026-08-28: Opt-in product telemetry

- **Authors:** @calvinmclean
- **Created:** 2026-08-28

## Summary

Add opt-in, installation-level product telemetry so we can understand how Obot is being adopted and which built-in capabilities are being used.

Obot will not send this additional telemetry until an Owner explicitly opts in. Consent will be persisted as a set of stable telemetry functionality identifiers rather than a single boolean. This representation allows future releases to add separately consented telemetry without treating an earlier opt-in as consent for newly introduced collection.

An opted-in installation will send aggregate telemetry once per day in a JSON `POST` request to upgrade-server alongside the existing daily upgrade-check workflow. The existing upgrade check itself will remain independent of telemetry consent.

## Related issues

- [obot-platform/obot#7693: Add opt-in product telemetry](https://github.com/obot-platform/obot/issues/7693)

## Related ODPs

None.

## Problem and motivation

During the recent overhaul of the MCP catalog, maintainers could not determine how disruptive the change would be to existing installations. More generally, Obot continues to add features without aggregate adoption data that would show which capabilities are widely used and therefore deserve greater investment or extra care during migrations.

Installation-level telemetry will provide evidence for prioritizing improvements and evaluating compatibility risk. Collection must remain narrow and transparent so it does not expose customer content or identify custom configuration.

## Goals

- Collect the aggregate metrics defined in the initial telemetry scope once per day from installations whose Owner has explicitly opted in.
- Preserve existing upgrade-check behavior regardless of whether telemetry consent is undecided, granted, or denied.
- Record exactly which telemetry functionality identifiers an Owner approved so future identifiers require separate consent.
- Keep telemetry failures isolated from normal Obot operation.
- Maintain compatibility as consent identifiers and payload fields evolve.

### Initial telemetry scope

The initial release defines one stable consent identifier for each telemetry type:

- `TotalUsers`: total number of users.
- `ActiveUsers`: number of active users during the previous full UTC day.
- `DeployedMCPServers`: total number of deployed MCP servers.
- `BuiltInMCPServerUsage`: for each server from Obot's built-in catalog, its stable name and ID, deployment count, and aggregate user usage count.
- `AuthProviderType`: configured authentication-provider type.
- `MCPAuditLogCount`: number of MCP audit-log records created during the previous full UTC day.
- `LLMAuditLogCount`: number of LLM audit-log records created during the previous full UTC day.

## Non-goals

- Collecting user-level activity, customer content, or unnecessarily granular data.
- Reporting the identity, configuration, deployment details, or usage of custom MCP servers.
- Collecting usernames, email addresses, user IDs, prompts, responses, audit-log contents, credentials, URLs, exact error messages, or other potentially identifying values.
- Defining an exhaustive long-term telemetry schema in the initial release.
- Providing fine-grained per-functionality selection in the initial consent UI. The persisted representation supports that option later, but the first UI remains all-or-nothing for the identifiers it discloses.
- Providing UI or API controls to view or change consent after the initial choice. In the initial implementation, changing a recorded choice requires direct database modification.

## Context and constraints

### Existing upgrade-check path

Obot already creates and persists an installation ID through `pkg/upgrade.GetInstallationID`. The helper calls the gateway client's `GetOrCreateProperty` using the `installation-id` property key and a generated UUID as the initial value. The telemetry request will reuse this identifier rather than introduce another installation identity.

The scheduled upgrade check currently lives in `pkg/api/handlers/version.go`. `VersionHandler.startUpgradeCheck` runs the check immediately and then on the existing daily interval. Telemetry consent must not disable or otherwise alter this request.

Telemetry will use the existing relationship with upgrade-server but will remain a distinct, opt-in request.

### Existing data sources

- The gateway client's `UserCount` method counts non-deleted users while excluding the bootstrap account.
- `ActiveUsersByDate` derives distinct users from API activity in a half-open `[start, end)` interval and excludes bootstrap, anonymous, empty, internal, and deleted users. The telemetry collector can reuse this existing activity definition with previous-full-day UTC boundaries.
- Built-in catalog entries already maintain aggregate user-count information. Telemetry must restrict per-server reporting to stable built-in catalog identities and must not fingerprint custom servers.
- MCP and LLM audit logs are persisted separately. Their daily telemetry values must be counts over the same previous-full-day UTC interval, without reading or sending log contents.

### Compatibility and privacy constraints

- Absence of an identifier means its collection is not authorized. A future release must not automatically add new identifiers to an installation's recorded consent.
- Send only aggregate installation-level values and maintain public documentation of every collected field and its cadence.
- Evolve payloads through additive optional fields. Deprecated fields may stop being populated but remain part of the compatible wire shape while supported versions still recognize them.

## Proposed design

### Consent and settings

- Show the telemetry choice only to Owners in the modal displayed during Owner login.
- Continue prompting Owners until one Owner explicitly opts in or opts out. Closing or dismissing the modal does not constitute consent.
- Present explicit opt-in and opt-out choices, explain what is collected and why, and link to complete public telemetry documentation.
- Persist consent at installation scope in the existing properties table under the `product_telemetry_consent` key as a JSON list of stable functionality identifiers. A missing property means consent is undecided; a present `[]` value means the Owner explicitly opted out.
- The initial all-or-nothing UI stores every identifier listed in **Initial telemetry scope** for opt-in or `[]` for opt-out.
- The initial implementation does not expose the recorded choice or allow it to be changed through the UI or API.

### Collection and transport

- Reuse the installation-ID helper from `pkg/upgrade`, but keep telemetry collection, transport, and scheduling out of the upgrade-check module.
- In an independent PR, move upgrade-check initialization, scheduling, transport, and state into a focused `pkg/upgrade.Checker`. `VersionHandler` will remain in `pkg/api/handlers` and read the checker's status through a small interface; telemetry orchestration will remain separate.
- Place telemetry collection, transport, and scheduling in `pkg/producttelemetry`. Start its independent, context-bound background job during `pkg/services.New`, after the gateway client and other collection dependencies are available. The job runs immediately and then every 24 hours at a fixed time, checking the current consent property on every run even when consent is undecided or opted out.
- Define consent and payload types in `apiclient/types` so `pkg/producttelemetry` can import the shared contract.
- Send a JSON `POST` to upgrade-server containing the existing installation ID and only the aggregate fields authorized by the persisted functionality identifiers.
- Represent each telemetry type with its own enum identifier and associate its collector and payload fields with that identifier.
- Use a dynamic mapping from recognized, consented identifiers to collector functions. The implementation will loop through enabled enums and construct the payload using only those fields.
- Design JSON payloads to be backward-compatible with append-only struct fields.

### Payload shape

The payload identifies a report by installation and UTC report date. `reportedAt` determines which of multiple reports for that date is newer. Optional scalar and count fields are pointers in the Go payload types: `null` means the metric could not be collected, while a non-null zero means it was collected and the measured value was zero.

```json
{
  "installationID": "7d7d83d8-2af0-4da8-ae2d-102d8eaa70be",
  "reportedAt": "2026-08-31T00:04:12Z",
  "metrics": {
    "totalUsers": 42,
    "activeUsers": null,
    "deployedMCPServers": 0,
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
    "llmAuditLogCount": null
  }
}
```

### Failure behavior

- A missing, empty, or unrecognized consent set results in no additional telemetry request.
- Collection or delivery failure must not fail the upgrade check or affect normal Obot operation.
- Failure to initialize or run product telemetry must be logged but must not prevent Obot from starting.
- Existing upgrade-check requests remain unchanged.
- Retry failed delivery with exponential backoff using the same report identity and `reportedAt` value. Reports are keyed by installation ID and report date; when more than one report exists for that key, the report with the newer `reportedAt` value replaces older data.

## Alternatives considered

### Status quo

Continue operating without additional product telemetry. This avoids new collection and consent mechanisms, but leaves maintainers unable to quantify adoption or assess the compatibility impact of changes. An explicit opt-out preserves this existing no-telemetry behavior.

### gRPC

Use gRPC between Obot and upgrade-server. gRPC offers a structured contract and established schema-evolution rules, but would introduce dependencies and build complexity without a need for streaming or high-throughput communication. A small daily JSON request is consistent with the existing HTTP integration.

## Trade-offs

- JSON over HTTP fits the existing dependency set and API style. It gives up compile-time enforcement across the network and some wire efficiency, neither of which is significant at a daily cadence and small payload size.
- Persisting a list of functionality identifiers is more complex than a boolean, but it makes consent boundaries explicit and prevents future collection from inheriting unrelated prior consent.

## Risks and open questions

- **User trust:** Even aggregate telemetry may make users uncomfortable. Mitigate this with explicit opt-in, plain-language disclosure, and complete public field documentation. The initial release does not provide UI or API controls to review or change the recorded choice.

## Rollout and migration

- Make the receiving upgrade-server capability available before releasing an Obot version that can send telemetry.
- Existing installations start with no telemetry functionality identifiers authorized and therefore send no additional telemetry.
- After upgrade, Owners are prompted until one records an explicit choice. Existing upgrade checks continue throughout this process.
- Observe request acceptance and delivery failures as installations upgrade and opt in.

## Testing and validation

### Obot

- Verify that undecided, empty, and unrecognized consent sets send no telemetry.
- Verify that opt-in enables only collectors associated with persisted, recognized identifiers.
- Verify Owner-only access, explicit initial opt-in/opt-out behavior, repeated prompting while the consent property is missing, and no prompting after either choice creates the property.
- Verify that the initial UI and API do not expose or modify an existing consent choice.
- Verify previous-full-day calculations use UTC half-open boundaries and reuse the existing active-user definition.
- Verify custom MCP servers and all prohibited customer-content fields are absent from generated payloads.
- Verify collector and transport errors do not affect the upgrade check or other Obot behavior.

### Contract and integration

- Verify request construction, schema compatibility, and malformed-response handling.
- Verify retries retain the same report identity and that a newer `reportedAt` report replaces older data for the same installation and report date.
- Verify telemetry failures do not affect the existing upgrade-check path.
- Add an end-to-end contract test using a representative authorized payload.

## References

- [Obot issue #7693](https://github.com/obot-platform/obot/issues/7693)
- Existing Obot upgrade client: `pkg/upgrade/client.go`
- Existing Obot upgrade scheduler: `pkg/api/handlers/version.go`
- Existing gateway user metrics: `pkg/gateway/client/user.go` and `pkg/gateway/client/apiactivity.go`
