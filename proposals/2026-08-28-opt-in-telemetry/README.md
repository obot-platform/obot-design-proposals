# YYYY-MM-DD: Proposal title

- **Authors:** @author
- **Created:** YYYY-MM-DD

## Summary

Add installation-level product telemetry so we can understand how Obot is being adopted and which built-in capabilities are being used.

Data will not be reported until an Owner opts-in to data collection. We will maintain an enum list of data that the owner consented to in order to allow adding new data collection without assuming the existing consent transfers.

Data will be reported using a daily POST request from the Obot installation alongside the daily upgrade check.


## Related issues

https://github.com/obot-platform/obot/issues/7693

## Related ODPs

N/A

## Problem and motivation

<!-- What problem are we solving, for whom, and why is it worth solving now? -->
In our recent overhaul of our MCP catalog, it was difficult to understand how disruptive that is to users. Additionally, we are continually growing our set of features but do not have a clear understanding of which features are most popular with users. This information will help us prioritize which features to enhance or change.

## Goals

<!-- Outcomes this design must achieve. Prefer observable results. -->
Collect daily information about how users are using Obot.

## Non-goals

<!-- Boundaries that prevent readers from assuming a broader scope. -->
Collecting unactionable or overly-granular information from installations.

## Context and constraints

<!--
Existing behavior and architecture, compatibility requirements, scale or
performance constraints, security boundaries, and relevant prior decisions.
Link to source or documentation where useful.
-->
Do not change daily upgrade checks as part of the data collection consent.

Use existing installation IDs.

Make sure we can add/remove fields from the collection set with backwards-compatiblity.


## Proposed design

<!--
Explain how the design works. Cover components, responsibilities, interfaces,
data flow, APIs, schemas, persistence, and failure behavior as applicable.
Use examples and diagrams when they make the design easier to evaluate.
-->

- Add to the existing `pkg/upgrade` client
- Separate the existing scheduled upgrade check out of the `pkg/api/handlers` since it's not really an API handler and move to a new package where this new functionality will also be added (TBD). If this is pursued, it will be done in an independent PR.
- Use enums for each metric type so we can record the user's consent. In this initial version, we will not provide a fine-grained selection mechanism and will present all-or-nothing. We will still persist the list of enums so we can optionally add fine-grained control later and add new metric types without assuming the user's consent. It will also allow the consent UI to show the user which metrics are new and which are already consented. Store these in the `properties` table as a key-value pair with JSON value
- Add types as part of Obot's API client module so they can be imported into the telemetry handler (TBD)
- Use versioned JSON payloads to aid in backwards compatiblity (get more detail on this design and whether or not it really matters if we keep the struct simple)
- Use some type of dynamic system to map the consented enums to functions that construct the data into the payload so we can easily loop through consented types and build the payload


## Alternatives considered

<!-- Include the status quo and the strongest credible alternatives. -->
- Status quo: the status quo can still be maintained by an opt-out. This will be clearly and openly presented to users so there will be no risk of mistrust
- gRPC: grpc is great for service-to-service communication with structured data and backwards-compatibility concerns. This, however, would introduce new dependencies and build complexity while we are not taking advantage of the high-throughput capabilities.


### Alternative name

<!-- Brief description and why it was not selected. -->
N/A

## Trade-offs

<!--
Describe the trade-offs of the proposed design relative to the important
alternatives. What becomes easier or harder? What cost or flexibility are we
giving up?
-->
- Using a JSON POST request fits current dependencies and API design. We do give up small payload size and strict types, but this is not significant for this scale or API lifecycle

## Risks and open questions

<!--
List known risks, unresolved decisions, and assumptions that need validation.
Name an owner or resolution point for open questions when possible.
-->
- Risk making users uncomfortable. This is mitigated by having a clear consent form and accompanying documentation


## Rollout and migration

<!--
Describe sequencing, compatibility during transition, feature gates, data
migration, observability, and rollback. Write "Not applicable" when appropriate.
-->
- This will be rolled-out to the destination service before being included in an Obot release so there is no risk of failed requests
- We can observe in the destination service to see that the functionality is working as users update and either opt-in or opt-out. We can assume opt-out when we see that the installation is updated but has not yet reported any data


## Testing and validation

<!--
How will we demonstrate correctness and know the change met its goals? Include
unit, integration, end-to-end, performance, security, or operational validation
as relevant.
-->
- Thorough unit testing in both impacted services


## References

<!-- Related proposals, ADRs, issues, prior art, or external documentation. -->
