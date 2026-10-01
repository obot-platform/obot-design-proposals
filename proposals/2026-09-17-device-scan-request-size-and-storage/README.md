# 2026-09-17: Device Scan Request and Storage Size

- **Authors:** @calvinmclean
- **Created:** 2026-09-17

## Summary

Make device scan failures visible and allow scans that exceed a single-request
limit to be submitted successfully. Submit one scan through multiple bounded
requests. Publish it to fleet inventory when complete; if the upload fails,
show failed or long-pending attempts and any received portions in scan history.

Fingerprinting raw content could later reduce repeated uploads and backend
storage, but it does not solve the initial large upload. It is therefore an
optional future optimization rather than the primary design.

## Related issues

- [obot-platform/obot#7506: Large device scan submissions fail without reporting scan failure](https://github.com/obot-platform/obot/issues/7506)

## Related ODPs

None

## Problem and motivation

Obot Sentry currently submits one complete device scan in one request. A large
scan can exceed either a reverse proxy's request limit or Obot's request limit.
The failure is visible only on the device, so administrators may continue
seeing stale inventory without knowing that a newer scan failed.

The reported production examples are not explained by project traversal depth.
One approximately 9.9 MB scan attributed about 95% of its payload to Codex
plugin-cache data, dominated by raw file contents and repeated skill and plugin
material. Compression can reduce bytes on the wire, but it does not guarantee
that a scan will fit every request limit.

Once failed attempts are recorded, "latest scan" becomes ambiguous. A failed
scan is the latest attempt but must not replace the last usable inventory.

## Goals

- Make pending and failed attempts visible to administrators when Obot is
  reachable.
- Preserve the latest usable inventory when a newer attempt fails.
- Accept a complete scan even when it cannot fit in one request.
- Keep per-request and whole-scan resource usage bounded.
- Prevent incomplete scans from appearing in inventory.
- Preserve received portions of a failed upload in scan history.
- Allow interrupted uploads to be retried without duplicating scan data.
- Remain compatible with older Sentry clients during rollout.

## Non-goals

- Guaranteeing failure reporting when the device cannot reach Obot.
- Bypassing deployment-specific limits with unbounded requests or scans.
- Reducing repeated backend storage as part of the multi-request design.
- Defining a general-purpose large-object upload protocol.
- Replacing the existing fleet inventory and scan-history experiences.

## Context and constraints

- A scan contains separate collections for clients, MCP servers, skills,
  plugins, and files. Obot already persists these collections separately under
  a scan record.
- A single collection, especially files, may itself exceed a request limit.
  Sending one request per collection is therefore not sufficient; a collection
  must be divisible across requests. Sentry already omits content for files
  over 1 MiB while retaining their path, size, and oversized status. Readable
  text files within that limit can keep their content.
- Obot does not control the reverse proxy configuration in every deployment,
  so increasing Obot's request limit alone cannot resolve all failures.
- Obot currently limits both the compressed request body and its decoded
  content to 8 MiB per request. A proxy can impose a lower limit on the
  compressed body before the request reaches Obot.
- Existing clients submit complete scans through the current endpoint and must
  continue to work during migration.
- Skill and plugin detail views display captured file content. This proposal
  preserves that content in complete scans; changing collection policy is a
  separate product decision.

## Proposed design

### Scan states

A scan attempt has one of three states:

- **Pending:** Obot has accepted the start of a scan but not the complete scan.
- **Successful:** Obot has accepted the complete scan.
- **Failed:** The scan could not be completed. Any portions Obot received remain
  available in scan history with the failure reason.

Only successful scans are usable inventory. Fleet views use the latest
successful scan for each device. Device and history views also show the latest
attempt and any received portions. Long-pending attempts are highlighted
alongside failed attempts without changing their stored status or replacing
older usable inventory.

### Multi-request scan submission

Add a scan-specific upload interface with three operations:

1. **Start** creates a pending scan and returns its scan ID.
2. **Append** submits a bounded part of one collection. Parts are independently
   retryable and idempotent, and collections may use as many parts as needed.
3. **Finalize** declares the expected parts for each collection. Obot checks
   that every declared part was received, including an explicit empty result
   for collections with no observations, before changing the scan from pending
   to successful. Until then, none of its observations appear in fleet
   inventory.

The interface exposes logical scan collections rather than database tables.
Obot authorizes each operation for the same device and installation and
enforces both per-request and aggregate scan limits. The whole-scan cap
defaults to 64 MiB of decoded data and is configurable by the operator. A scan
that exceeds its configured cap fails with its received portions visible in
history.

Sentry groups observations into parts targeting at most 896 KiB of uncompressed
request data, then compresses each request. This leaves some room below Nginx's
default 1 MiB compressed-body limit even if compression saves little. A
captured file stays intact: if it does not fit alongside other observations,
Sentry sends it in its own part, which may exceed that target. Existing
per-file capture limits remain unchanged. Proxy acceptance is not guaranteed,
especially for a near-1 MiB file or a deployment with a lower limit. Obot
enforces per-request limits on both compressed and decoded bodies. A retry of
an acknowledged part must have the same content; a changed part with the same
identity is rejected.

Sentry may resume a pending scan after a transient failure by resending only
unacknowledged parts. Obot allows one pending scan per device; starting a new
scan for that device marks the earlier pending scan as failed with a superseded
reason. Distinct scan IDs prevent parts from one attempt changing another.

On HTTP 413, Sentry does not resize or retry the rejected part; it reports a
request-too-large failure for the attempt through a small, best-effort status
request. Sentry likewise reports other non-recoverable errors when it abandons
a pending scan. If that report cannot reach Obot, the attempt remains pending;
a later scan for the device supersedes it. A failed scan ID cannot later be
finalized.

Received portions of failed or long-pending attempts remain visible until
normal scan-history retention deletes them. The current default is 90 days;
zero disables automatic cleanup. At the proposed 64 MiB cap, one near-limit
failure per day could retain about 5.6 GiB of partial data per device over 90
days. This is a capacity bound, not a production estimate.

If submission fails before Obot creates a pending scan, Sentry makes a
best-effort, small failure report when the server is reachable. Failed attempts
never replace the last successful inventory. Failure reports use a bounded
reason category and safe message, without raw proxy responses or local file
paths.

## Alternatives considered

### Report failed scans only

Keep single-request scans and report failed uploads separately. Administrators
would see the failures, but large scans would still be rejected and leave
inventory stale.

### Fingerprinted raw content

Store raw content once under a fingerprint and let later scans refer to it.
This can reduce repeated transfer and backend storage, but it cannot guarantee
that previously unseen content will fit in the first request. It also requires
reference-aware retention, protection against cross-tenant existence leaks,
and recovery when client and server knowledge disagree.

Fingerprinting may be added later, narrowly for raw content, if measurements
show that storage duplication is significant over the actual scan-retention
window. It can use the multi-request interface when the first set of artifacts
is large.

### Compression and larger limits only

Keep each scan in one request, compress it, and raise the accepted limit. This
is a smaller protocol change but remains dependent on every proxy in the path,
increases resource exposure, and provides no reliable upper bound on future
scan growth.

### gRPC streaming

Send a scan through one client-streaming gRPC call. This offers flow control
and avoids repeated request setup, but the stream is still one HTTP/2 request
subject to proxy body limits. Protobuf would reduce some metadata overhead,
not the captured file content that dominates large scans. Supporting gRPC
through deployment proxies and resuming interrupted streams would add
complexity without resolving the reported size rejection.

### WebSocket upload

After a WebSocket upgrade, scan data is tunneled rather than sent as an HTTP
request body. This could avoid a proxy's body limit, including for an intact
near-1 MiB file. It would still need bounded messages, acknowledgments, and
resume after disconnection, while depending on WebSocket support and long-lived
connections across deployments. For the reported scan size, this added
transport and operational complexity is not justified over a few dozen HTTP
requests that can reuse a connection. Reconsider it if single-file parts
commonly fail at deployment proxy limits.

### Retry without bulky content

After a size rejection, retry a smaller scan that omits optional raw content.
This could provide quicker relief, but adds a second, incomplete scan format
that would remain after multi-request submission is available. It also does not
meet the goal of accepting a complete scan.

## Trade-offs

- Multi-request submission accepts complete first-time scans and is independent
  of one-request limits, at the cost of pending state, finalization, and cleanup.
- Aligning parts with logical scan collections keeps the interface small while
  allowing any large collection to be divided further.
- Keeping files intact avoids file-chunk reassembly but leaves a near-limit
  captured file vulnerable to a proxy's lower per-request limit.
- Incomplete scans stay out of fleet inventory while received portions remain
  viewable in scan history.
- Idempotent parts make retries safe but require stable scan and part identity.
- One pending scan per device bounds unfinished storage but means a newer attempt
  ends an older unfinished upload.
- This design improves submission reliability but does not reduce repeated
  backend storage; fingerprinting remains a separate possible optimization.
- Separating latest attempt from latest successful scan makes failures visible,
  but consumers must choose which meaning of "latest" they need.

## Risks and open questions

- **Capacity validation:** Validate the proposed 64 MiB whole-scan default and
  storage cost of retaining failed portions for the configured scan-history
  period against representative scans and deployment budgets before release.
- **Long-pending display:** Choose when a pending attempt is highlighted as
  long-pending in device and history views.
- **Server rollback:** Ensure older inventory queries cannot surface pending
  partial scans before enabling the new client path.
- **Version gate:** Identify the first Obot release with multi-request uploads
  so Sentry can choose the correct submission format.
- **Production distribution:** One reported 9.9 MB scan was dominated by file
  content from the Codex plugin cache. Measure broader scan sizes and proxy
  limits before treating it as representative.

## Rollout and migration

1. Add attempt status, failure reporting, administrator visibility, and the
   multi-request interface while retaining the existing complete-scan endpoint.
   Make the Obot version, without unrelated server details, available to
   Sentry's device credential. Older clients continue submitting complete
   scans as successful attempts.
2. Newer Sentry checks the Obot version before submitting. It uses multi-request
   uploads only with a supporting version; for older or unknown versions, it
   uses the existing endpoint. Large scans can still fail until the server is
   upgraded.

Rollback disables the new client path and leaves the existing endpoint
available. Pending attempts must remain excluded from fleet inventory through
server rollback.

## Testing and validation

- Submit the reported large-scan shape through bounded parts, keeping captured
  files intact, and verify proxy and Obot size rejection report safe failures.
- Verify duplicate and resumed parts are idempotent, while changed or missing
  parts cannot be finalized.
- Verify per-request and configurable whole-scan limits, including failure
  reporting without repartitioning after a 413.
- Verify only complete scans enter fleet inventory; failed and long-pending
  attempts retain received portions in history until normal retention.
- Verify a new scan supersedes the device's pending attempt and that Sentry
  chooses the correct format for supporting, older, and unknown server versions.

## References

- [Issue #7506 and production payload breakdown](https://github.com/obot-platform/obot/issues/7506)
- [Nginx `client_max_body_size` documentation](https://nginx.org/en/docs/http/ngx_http_core_module.html#client_max_body_size)
- [gRPC over HTTP/2](https://grpc.io/blog/grpc-on-http2/)
- [Nginx WebSocket proxying](https://nginx.org/en/docs/http/websocket.html)
- Existing Obot scan model: `pkg/gateway/types/devicescan.go`
- Existing Obot scan persistence: `pkg/gateway/client/devicescan.go`
- Existing Obot scan ingest: `pkg/api/handlers/devicescans.go`
- Existing Sentry scan submission: `pkg/client/devicescan.go`
