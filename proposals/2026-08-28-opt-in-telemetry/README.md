# 2026-08-28: Opt-in product telemetry

- **Authors:** @calvinmclean
- **Created:** 2026-08-28

## Summary

Add installation-level product telemetry to understand Obot adoption and use of built-in capabilities. Move distribution and engine reporting from the upgrade check into this collection while also reporting the current version in both. Every installation reports these three operational fields; self-hosted installations add product-usage metrics after an Owner opts in, while Obot Cloud always adds them.

For self-hosted installations, consent is a boolean that Owners can review and change. Opt-in applies to current and future product-usage metrics.

## Related issues

- [obot-platform/obot#7693: Add opt-in product telemetry](https://github.com/obot-platform/obot/issues/7693)

## Related ODPs

None.

## Problem and motivation

Obot lacks aggregate adoption data for prioritizing features and evaluating the compatibility impact of changes such as the recent MCP catalog overhaul. This proposal adds narrowly scoped telemetry without collecting customer content (audit logs, custom MCP entries, MCP configurations, etc.) or system-level configurations that might contain customer details.

## Goals

- Collect the initial aggregate metrics daily from opted-in self-hosted installations and Obot Cloud.
- Preserve existing upgrade-check behavior and normal Obot operation. Migrate metrics collected by upgrade-check to be part of the new API.
- Support compatible evolution of payload fields.

### Initial telemetry scope

The initial product-usage metrics are:

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

Every report also includes the following operational installation metadata independently of product-analytics consent:

- `Distribution`: `Unlicensed`, `Community`, or `Enterprise` for self-hosted installations, and `Cloud` for Obot Cloud.
- `Engine`: configured MCP runtime engine, normalized as it is for the existing upgrade check.
- `CurrentVersion`: running Obot version.

## Non-goals

- Collecting user-level activity, customer content, credentials, configuration values, URLs, exact errors, or other identifying data.
- Reporting the identity or configuration of custom MCP servers.
- Defining an exhaustive long-term telemetry schema.
- Providing per-metric consent choices.

## Context and constraints

Obot already stores an installation ID through `pkg/upgrade.GetInstallationID` and performs a daily upgrade check from `pkg/api/handlers/version.go`. Telemetry will reuse the installation ID and upgrade-server relationship but remain independent of the upgrade check.

The upgrade check currently reports `oss` or `enterprise` based only on whether any valid license exists. Community licensing makes that test an invalid proxy for distribution, and the current configuration has no explicit Obot Cloud signal.

Existing data sources include:

- `UserCount`, which excludes deleted users and the bootstrap account.
- `ActiveUsersByDate`, which excludes bootstrap, anonymous, empty, internal, and deleted users.
- Aggregate user counts on built-in catalog entries.
- Separately persisted MCP and LLM audit logs.

Telemetry must send only aggregate installation-level values, document every collected field and its cadence, and evolve through additive optional fields. Self-hosted product-usage collection requires a `true` consent value.

## Proposed design

### Consent

- Show Owners an explicit all-or-nothing choice during login until one records a decision. Dismissing the modal is not consent.
- Explain the collection and link to its complete public documentation.
- Store consent in the installation-level `product_telemetry_consent` property as a boolean. A missing property is undecided, `false` is opted out, and `true` opts in to all current and future product-usage metrics.
- Add an Owner-only API to read and set the boolean. The initial prompt and an Owner settings control use the same API, allowing consent to be reviewed and changed later.
- Obot Cloud sets `OBOT_SERVER_PRODUCT_ANALYTICS_FORCE_ENABLED=true`. This supplies effective consent independently of the `product_telemetry_consent` property: collect all product-usage metrics, suppress the consent UI, and provide no opt-out. The property is neither required nor authoritative when the environment variable is true, and the API does not allow changing effective consent.

### Collection and transport

- In an independent PR, move upgrade-check lifecycle and state into `pkg/upgrade.Checker`; `VersionHandler` will read its status through a small interface. This is not strictly necessary, but is an opportunity for clearer organization that was identified.
- Put telemetry collection, transport, and scheduling in `pkg/producttelemetry`. Start its context-bound job during `pkg/services.New`; it runs immediately and then daily at a fixed time, reading consent on each run.
- Reuse `pkg/upgrade` only for the installation ID. Define payload types in `apiclient/types`.
- Always collect the operational installation metadata. When effective consent is true, collect every product-usage metric defined by that release; otherwise send a metadata-only JSON `POST` to upgrade-server.

### Relocating upgrade-check metadata

Add `distribution`, `engine`, and `currentVersion` to the telemetry report so installation metadata is collected together. Remove `distribution` and `engine` from `/check-upgrade`, but retain its installation ID and current version so it can continue determining upgrade availability and the latest version.

- Obot Cloud explicitly sets `Cloud`. Self-hosted installations report `Community` or `Enterprise` from the license type, or `Unlicensed` when they have no valid license; do not classify every valid license as `Enterprise`.
- Report all three regardless of product-analytics consent. Opted-out or undecided installations send a metadata-only report and continue to receive upgrade checks.
- During rollout, send distribution and engine through both requests until the telemetry receiver accepts them and `/check-upgrade` supports requests without them. Then remove those two query parameters from Obot; current version remains on both requests.

### Payload

Reports are identified by installation ID and the UTC date of `reportedAt`. A newer `reportedAt` replaces older data for that date. Optional scalar and count fields use Go pointers: `null` means unavailable, while `0` means a measured zero. A metadata-only report omits `metrics`.

```json
{
  "installationID": "7d7d83d8-2af0-4da8-ae2d-102d8eaa70be",
  "reportedAt": "2026-08-31T00:04:12Z",
  "distribution": "Cloud",
  "engine": "kubernetes",
  "currentVersion": "v0.26.0",
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

- On self-hosted installations, undecided or opted-out consent produces a metadata-only request with no product-usage metrics.
- Telemetry initialization, collection, and delivery failures are logged but never block startup or normal operation.
- Failed delivery uses exponential backoff with the same installation ID and `reportedAt`.

## Alternatives considered

### Status quo

Collect nothing. This avoids new consent and collection mechanisms but leaves maintainers unable to quantify adoption or compatibility risk. Opt-out preserves this behavior.

### gRPC

Use gRPC for a structured, evolvable contract. It adds dependencies and build complexity without a need for streaming or high throughput; one small daily JSON request fits the existing HTTP integration.

## Trade-offs

- JSON is simple and consistent with the current integration, at the cost of compile-time contract enforcement and wire efficiency.
- Boolean consent keeps the UI, API, and collection path simple, but automatically authorizes product-usage metrics added after opt-in. Public documentation must remain current so Owners can make and revisit an informed choice.

## Risks and open questions

- **User trust:** Mitigate discomfort with explicit opt-in, plain-language disclosure, complete public documentation, and controls to review or change consent.

## Rollout and migration

- Deploy the receiving upgrade-server capability before releasing the Obot sender.
- Migrate distribution and engine using the compatibility sequence in **Relocating upgrade-check metadata**; add current version to telemetry without removing it from `/check-upgrade`.
- Existing self-hosted installations begin undecided and send only operational metadata until an Owner opts in. Obot Cloud starts fully enabled without prompting.
- Monitor request acceptance and delivery failures as installations upgrade.

## Testing and validation

- Verify missing, `false`, and `true` consent; Owner-only API access; repeated prompting while undecided; and later UI/API changes in both directions.
- Verify `OBOT_SERVER_PRODUCT_ANALYTICS_FORCE_ENABLED=true` sends all telemetry without a consent property or UI and overrides stored undecided or opt-out state.
- Verify opted-out and undecided installations send only distribution, engine, and current version.
- Verify upgrade checks continue for installations that do not send product-usage metrics, using the current version supplied directly to `/check-upgrade`.
- Verify all product-usage collectors run only when effective consent is true, including metrics added after the original opt-in.
- Verify previous-full-day UTC boundaries, report-time totals, and existing count definitions.
- Verify custom MCP servers and prohibited data never enter a payload.
- Verify `null` versus measured zero serialization.
- Verify telemetry failures do not affect startup, normal operation, or upgrade checks.
- Verify request compatibility, retry identity, and newer-report replacement.

## References

- [Obot issue #7693](https://github.com/obot-platform/obot/issues/7693)
- Existing Obot upgrade client: `pkg/upgrade/client.go`
- Existing Obot upgrade scheduler: `pkg/api/handlers/version.go`
- Existing gateway user metrics: `pkg/gateway/client/user.go` and `pkg/gateway/client/apiactivity.go`
