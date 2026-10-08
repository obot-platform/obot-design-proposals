# 2026-10-08: Langfuse audit log sink

- **Authors:** @strelok89
- **Created:** 2026-10-08

## Summary

Add an optional audit log sink that continuously ships MCP tool calls from Obot's persisted
audit logs to Langfuse, using Langfuse's OTLP traces endpoint. A leader-run controller reads
new rows past a stored cursor, maps them to OTLP spans with Langfuse and OpenTelemetry GenAI
attributes, and advances the cursor only after Langfuse accepts the batch. The sink is off by
default, never runs in the gateway request path, and sends request/response bodies only when
an Auditor enables it.

## Related issues

- [obot-platform/obot#8183: Stream MCP audit logs to Langfuse](https://github.com/obot-platform/obot/issues/8183)

## Related ODPs

None.

## Problem and motivation

Obot's MCP audit logs hold what an LLM observability tool needs: who called which tool,
with what arguments, what came back, and how long it took. Today the data leaves Obot only as
JSONL files in object storage
([audit log export](https://docs.obot.ai/configuration/audit-log-export/)), so every team
that wants it in Langfuse writes and operates its own reshaping job. That job has to:

- read bodies through `/api/mcp-audit-logs/detail/{id}` one row at a time, because list
  responses always omit them (`pkg/api/handlers/mcpgateway/auditlog.go`, `ListAuditLogs`);
- hold an Auditor API key, since only Auditors may read bodies;
- handle the request/response merge, retries, deduplication and its own cursor, because
  scheduled exports cover time windows and track no position.

Obot's OpenTelemetry export (`pkg/otel/otel.go`) does not fill the gap: the only spans are
`otelhttp` server spans named by route pattern, with no tool, user, session or payload.

## Goals

- MCP `tools/call` records appear in Langfuse within about a minute of being persisted,
  without any external job.
- Records are attributed to the user by email and grouped into Langfuse sessions.
- A Langfuse outage or misconfiguration never affects MCP traffic.
- No record is skipped silently: delivery is at-least-once within the retention window, and
  any gap is reported on the sink's status.
- Shipping request/response bodies requires the same privilege as exporting them today.

## Non-goals

- **LLM gateway audit logs.** They map naturally to Langfuse `generation` observations (model,
  token usage, prompt and completion) and reuse this controller; deferred to a follow-up to
  keep the first change small.
- **Local-agent (device) tool-call logs.** Same table, but they carry hostnames, working
  directories and git metadata; a follow-up with its own privacy review.
- Linking an MCP tool call to the LLM request that caused it. Obot has no shared trace
  context between the two today.
- Sinks other than Langfuse. The design keeps a small interface so a generic OTLP sink can
  follow.
- Backfilling records older than the retention window, or reading data back from Langfuse.

## Context and constraints

- **Write path.** `LogMCPAuditEntry` (`pkg/gateway/client/auditlogpersister.go`) runs on every
  replica, encrypts bodies and buffers entries; the persistence loop flushes every
  `OBOT_SERVER_MCPAUDIT_LOG_PERSIST_INTERVAL_SECONDS` (default 5). A failed batch is re-queued.
  `insertMCPAuditLogs` (`pkg/gateway/client/mcpauditlog.go`) merges a response-only entry into
  its pending request row, so a row is not final when first inserted.
- **Export subsystem.** `AuditLogExport` and `ScheduledAuditLogExport` are storage types;
  credentials live in the gateway credential store; `StorageProvider` is object-store only
  (`Test`, `Upload`), so it is not a fit for an HTTP API.
- **Leader election.** Controllers run on the elected `obot-controller` leader, with the lock
  in Postgres (`adr/2026-09-02-sql-leader-lock.md`).
- **Body access.** Only Auditors can read or export bodies
  (`auditlog.go`, `canAccessFullPayload = req.UserIsAuditor()`).
- **User identity.** Audit rows store the Obot user ID; email is resolved through the gateway
  user store (`UserByIDIncludeDeleted` in `pkg/gateway/client/user.go`, so rows from deleted
  users still resolve).
- **Langfuse ingestion.** The legacy `POST /api/public/ingestion` API is deprecated and stops
  accepting trace and observation events on Langfuse Cloud on 2026-11-16; the replacement is
  `POST /api/public/otel/v1/traces` (OTLP over HTTP, JSON or protobuf, no gRPC). Langfuse
  stores traces only.

## Proposed design

### Components

```mermaid
flowchart LR
  GW[MCP gateway] -->|LogMCPAuditEntry| DB[(mcp audit log table)]
  C[AuditLogSink controller<br/>leader only] -->|rows past cursor, settled| DB
  C -->|OTLP/HTTP protobuf, Basic auth| LF[Langfuse /api/public/otel/v1/traces]
  C -->|cursor, lastError, gaps| S[AuditLogSink status]
```

1. **`AuditLogSink` storage type** (next to `AuditLogExport`):

   ```yaml
   spec:
     displayName: Langfuse
     type: langfuse                  # only value in this proposal
     enabled: true
     callTypes: [tools/call]         # default
     filters: {...}                  # same shape as export Filters
     withRequestAndResponse: false   # Auditor-only to set true
     maxBodyBytes: 262144            # truncate larger bodies, mark as truncated
   status:
     cursor: {createdAt: ..., id: 12345}
     lastSentAt: ...
     lastError: ""
     gaps: []                        # windows lost to retention while the sink was failing
   ```

   An installation may define several sinks (for example one per Langfuse project), each with
   its own cursor. The status keeps a per-source cursor map so LLM logs can be added later
   without a schema change.

2. **Credentials** in the gateway credential store under a per-sink context (as
   `audit-log-export-storage-credentials` does): Langfuse base URL, public key, secret key.
   Write-only through the API, with a `Test` endpoint that sends one empty OTLP request.

3. **Controller** on the leader. Every poll interval (default 15s):
   - Select rows with `(created_at, id) > cursor` and `created_at < now() - settle`, ordered by
     `(created_at, id)`, up to a batch size.
   - `settle` (default 60s, must exceed the persist interval) gives response entries time to
     merge into their request rows. A row still without a response after `settle` is sent as
     incomplete.
   - Resolve user emails for the batch (cached), decrypt bodies only when
     `withRequestAndResponse` is true, map to spans, send, and on a 2xx write the new cursor to
     status. On failure, keep the cursor and back off (retry client modelled on
     `pkg/producttelemetry/client.go`).
   - Each poll re-reads a short overlap behind the cursor to catch rows whose persistence was
     retried after later rows had committed. Span IDs are deterministic, so a re-sent row maps
     to the same span (see open question 1).
   - If the oldest unsent row has passed retention, record the lost window in `status.gaps`
     and continue from the oldest remaining row.

4. **Sink interface**, so the Langfuse code is one implementation:

   ```go
   type Sink interface {
       Test(ctx context.Context) error
       Send(ctx context.Context, records []Record) error
   }
   ```

### Mapping to OTLP spans

All spans carry the resource attribute `service.name=obot` and the header
`x-langfuse-ingestion-version: 4`.

| Langfuse field | From the MCP audit row |
|---|---|
| Trace ID (16 bytes) | `sha256("mcp" + mcpID + userID + sessionID)[:16]` |
| Span ID (8 bytes) | `sha256("mcp" + id)[:8]` |
| Name | `callIdentifier` (tool name) |
| `langfuse.observation.type` | `tool` |
| `session.id` | `sessionID` |
| `user.id` | user's newest email, resolved at send time; Obot user ID if the user has no email |
| Input / output | `gen_ai.tool.call.arguments` / `gen_ai.tool.call.result`, only with `withRequestAndResponse` |
| Status | `error`, `responseStatus` |
| Metadata | Obot user ID, server display name, catalog entry, client name and version, API key name, processing time |
| Timing | `createdAt` to `createdAt + processingTimeMs` |

Hashing keeps IDs stable across re-sends and fixed-width as OTLP requires. Spans are built as
read-only span snapshots with these IDs and passed to the `otlptracehttp` exporter directly;
the tracer's random ID generator and batch processor are not used.

### Security and privacy

- Creating or updating a sink with `withRequestAndResponse: true` requires the Auditor role,
  the same rule as exporting bodies. Admins may manage metadata-only sinks.
- Every span carries the user's email. This is personal data leaving Obot for an external
  system, so the sink's admin UI states it, and the docs say so alongside the body warning.
- Decrypted bodies exist only in memory for the duration of a send.
- HTTPS is required unless the operator explicitly allows plain HTTP (for in-cluster
  Langfuse).

## Alternatives considered

### Status quo: object-store export plus an external job

Works today, but each operator rebuilds the same reshaping, cursor and dedup logic, and the
job needs an Auditor key. Scheduled exports are window-based with no cursor.

### Push from `LogMCPAuditEntry`

Lowest latency, but it sees entries before the request/response merge, runs on every
replica, and loses buffered entries on restart. It also puts sink back-pressure next to the
gateway path.

### MCP filters (webhooks)

Filters see requests and responses in real time, but they fail closed (a filter error returns
an error to the client, `proxy_hooks.go`) and receive only the JSON-RPC message, with no user
or session.

### Obot's existing OpenTelemetry export

No code needed, but the spans are HTTP server spans without tool, user or payloads. Adding
content to them would mean new instrumentation in the gateway path and would bypass the
Auditor rule.

### Langfuse legacy ingestion API

Richer native event types, but deprecated with a Cloud sunset on 2026-11-16.

### A Langfuse SDK

Langfuse ships official SDKs for Python and JS/TS only. The community Go SDKs
(`henomis/langfuse-go`, `fugue-labs/langfuse-go`) wrap the deprecated ingestion API. Langfuse's
guidance for custom instrumentation is to send OTLP to `/api/public/otel/v1/traces`. The sink
uses the OpenTelemetry Go SDK's `otlptracehttp` exporter, already in Obot's dependency tree via
`autoexport`, and calls `ExportSpans` synchronously rather than through a
`BatchSpanProcessor`, so the cursor advances only after Langfuse confirms the batch.

### Generic OTLP sink instead of Langfuse

Viable and vendor-neutral, and most of this design carries over. Langfuse is proposed first
because its attribute mapping (observation types, sessions, users) is well defined. A
`type: otlp` sink can reuse the controller and mapping without the `langfuse.*` attributes.

## Trade-offs

- Latency is bounded below by `settle` plus the poll interval (about a minute by default), in
  exchange for complete, merged rows and a single writer.
- A new cursor store (the sink's status) is added; exports have none today.
- Polling adds one indexed range query per sink per interval on the leader.
- Email attribution makes Langfuse readable without a lookup, at the cost of sending personal
  data on every span.

## Risks and open questions

1. **Idempotency in Langfuse.** The overlap re-read relies on Langfuse treating a re-sent span
   with the same trace and span ID as an update, not a duplicate. Not yet verified against
   Langfuse v4 OTLP ingestion. Owner: author, before implementation; fallback is no overlap and
   a strictly monotonic cursor.
2. **Late commits.** A persistence batch that is retried can commit rows older than the cursor.
   The overlap covers short delays; the right overlap length depends on (1).
3. **Payload size.** Langfuse's maximum OTLP request and attribute size needs confirming;
   `maxBodyBytes` truncation is the proposed guard.
4. **Email changes.** Decided: spans always carry the user's newest email, looked up at send
   time, never the email recorded when the call was made. The email cache has a short TTL
   (default 5 minutes) so a change takes effect quickly. Spans already sent are not rewritten,
   so calls sent before a change stay under the old email in Langfuse; the Obot user ID in
   metadata links both.

## Rollout and migration

- New storage type and controller; no change to existing tables or exports.
- Off by default. A new sink's cursor starts at its creation time; an optional `startTime`
  within retention allows a bounded backfill.
- Disable by setting `enabled: false` (cursor kept) or delete the sink.

## Testing and validation

- Unit tests for row-to-span mapping, deterministic IDs, email resolution and fallback, body
  gating and truncation.
- Controller tests with a fake OTLP receiver: cursor advance on 2xx, no advance on failure,
  backoff, overlap re-read, gap recording when rows age out.
- Integration test against Langfuse in Docker: tool observations appear with the expected
  session, user and (when enabled) input/output, and re-sends do not duplicate.
- Authorization tests: an Admin without Auditor cannot enable bodies.

## References

- [Audit log export](https://docs.obot.ai/configuration/audit-log-export/)
- [Langfuse OpenTelemetry integration](https://langfuse.com/integrations/native/opentelemetry)
- `adr/2026-09-02-sql-leader-lock.md`
- `pkg/gateway/client/auditlogpersister.go`, `pkg/gateway/client/mcpauditlog.go`,
  `pkg/gateway/client/user.go`, `pkg/controller/handlers/auditlogexport/`
