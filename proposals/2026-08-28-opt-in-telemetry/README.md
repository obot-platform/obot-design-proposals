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
- Allow an Owner to review and change the installation-level choice without restarting Obot.
- Keep telemetry failures isolated from normal Obot operation.
- Maintain compatibility as consent identifiers and payload fields evolve.

### Initial telemetry scope

The initial functionality identifier covers these metrics from the related issue:

- Total number of users.
- Number of active users during the previous full UTC day.
- Total number of deployed MCP servers.
- For each server from Obot's built-in catalog: its stable name and ID, deployment count, and aggregate user usage count.
- Configured authentication-provider type.
- Number of MCP audit-log records created during the previous full UTC day.
- Number of LLM audit-log records created during the previous full UTC day.

## Non-goals

- Collecting user-level activity, customer content, or unnecessarily granular data.
- Reporting the identity, configuration, deployment details, or usage of custom MCP servers.
- Collecting usernames, email addresses, user IDs, prompts, responses, audit-log contents, credentials, URLs, exact error messages, or other potentially identifying values.
- Defining an exhaustive long-term telemetry schema in the initial release.
- Providing fine-grained per-functionality selection in the initial consent UI. The persisted representation supports that option later, but the first UI remains all-or-nothing for the identifiers it discloses.

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

- Persist consent at installation scope in the existing properties table as a key/value property whose value is a JSON list of stable functionality identifiers.
- Absence of an identifier means its collection is not authorized. A future release must not automatically add new identifiers to an installation's recorded consent.
- Send only aggregate installation-level values and maintain public documentation of every collected field and its cadence.
- Add and remove payload fields without breaking supported Obot or upgrade-server versions.

## Proposed design

### Consent and settings

- Show the telemetry choice only to Owners in the modal displayed during Owner login.
- Continue prompting Owners until one Owner explicitly opts in or opts out. Closing or dismissing the modal does not constitute consent.
- Present explicit opt-in and opt-out choices, explain what is collected and why, and link to complete public telemetry documentation.
- Persist the decision at installation scope so other Owners are not prompted for the same disclosed functionality identifiers.
- The initial UI presents one all-or-nothing choice. Opt-in writes all functionality identifiers disclosed by that UI; opt-out leaves the set empty or removes those identifiers.

### Collection and transport

- Add telemetry transport behavior to the existing `pkg/upgrade` client.
- Keep the daily telemetry operation associated with the existing upgrade-check schedule, while ensuring the upgrade check continues independently of consent and telemetry failures.
- Separate scheduled upgrade-check orchestration from `pkg/api/handlers`, because it is background work rather than an API handler, and place the telemetry scheduler alongside it in a new package (package name and boundary TBD). If pursued, this refactor will be delivered in an independent PR.
- Define consent and payload types in Obot's API client module so the telemetry handler can import the shared contract.
- Send a JSON `POST` to upgrade-server containing the existing installation ID and only the aggregate fields authorized by the persisted functionality identifiers.
- Use enums for telemetry functionality identifiers. The initial release may define one identifier covering all metrics in **Initial telemetry scope**.
- Use a dynamic mapping from recognized, consented identifiers to collector functions. The implementation will loop through enabled enums and construct the payload using only those fields.
- Design JSON payloads to be backwards-compatible with append-only struct fields

### Failure behavior

- A missing, empty, or unrecognized consent set results in no additional telemetry request.
- Collection or delivery failure must not fail the upgrade check or affect normal Obot operation.
- Existing upgrade-check requests remain unchanged.
- Use exponential backoff for retries to prevent missed data. Since it is reported once daily, the destination can handle duplicates.

## Alternatives considered

### Status quo

Continue operating without additional product telemetry. This avoids new collection and consent mechanisms, but leaves maintainers unable to quantify adoption or assess the compatibility impact of changes.

The rough draft also states that “the status quo can still be maintained by an opt-out.” The intended meaning needs confirmation because explicit opt-out preserves current no-telemetry behavior, while the proposal otherwise requires opt-in before collection.

### gRPC

Use gRPC between Obot and upgrade-server. gRPC offers a structured contract and established schema-evolution rules, but would introduce dependencies and build complexity without a need for streaming or high-throughput communication. A small daily JSON request is consistent with the existing HTTP integration.

## Trade-offs

- JSON over HTTP fits the existing dependency set and API style. It gives up compile-time enforcement across the network and some wire efficiency, neither of which is significant at a daily cadence and small payload size.
- Persisting a list of functionality identifiers is more complex than a boolean, but it makes consent boundaries explicit and prevents future collection from inheriting unrelated prior consent.

## Risks and open questions

- **User trust:** Even aggregate telemetry may make users uncomfortable. Mitigate this with explicit opt-in, plain-language disclosure, complete public field documentation, and an Owner-only control that can disable collection immediately.
- **Package ownership:** What package should own background upgrade and telemetry scheduling after it moves out of `pkg/api/handlers`?
- **Shared contracts:** Which API client package should own the consent identifiers and payload types?

## Rollout and migration

- Make the receiving upgrade-server capability available before releasing an Obot version that can send telemetry.
- Existing installations start with no telemetry functionality identifiers authorized and therefore send no additional telemetry.
- After upgrade, Owners are prompted until one records an explicit choice. Existing upgrade checks continue throughout this process.
- Observe request acceptance and delivery failures as installations upgrade and opt in.

## Testing and validation

### Obot

- Verify that undecided, empty, and unrecognized consent sets send no telemetry.
- Verify that opt-in enables only collectors associated with persisted, recognized identifiers.
- Verify Owner-only access, explicit opt-in/opt-out behavior, repeated prompting while undecided, and immediate disablement after opt-out.
- Verify previous-full-day calculations use UTC half-open boundaries and reuse the existing active-user definition.
- Verify custom MCP servers and all prohibited customer-content fields are absent from generated payloads.
- Verify collector and transport errors do not affect the upgrade check or other Obot behavior.

### Contract and integration

- Verify request construction, schema compatibility, and malformed-response handling.
- Verify retry and duplicate-delivery behavior once delivery semantics are selected.
- Verify telemetry failures do not affect the existing upgrade-check path.
- Add an end-to-end contract test using a representative authorized payload.

## References

- [Obot issue #7693](https://github.com/obot-platform/obot/issues/7693)
- Existing Obot upgrade client: `pkg/upgrade/client.go`
- Existing Obot upgrade scheduler: `pkg/api/handlers/version.go`
- Existing gateway user metrics: `pkg/gateway/client/user.go` and `pkg/gateway/client/apiactivity.go`
