# 2026-10-12: Provide Localization/Translation Layer for Server-side Responses

- **Authors:** @ivyjeong13
- **Created:** 2026-10-12

## Summary

Define a request-scoped localization contract for Obot API responses, starting with auth providers, model providers, local auth, and the associated SCIM setup flow responses. Obot-owned text lives in reviewable JSON message catalogs in `otto8/pkg/i18n/messages`. The API selects a locale from `Accept-Language`, renders human-facing text at the response boundary. Provider-owned display text will be switched to handlebar variable references that will utilize the aforementioned JSON message catalogs.

## Related issues

- [obot-platform/obot#8191](https://github.com/obot-platform/obot/issues/8191) — tracking issue for API localization.

## Related ODPs

Not applicable.

## Problem and motivation

The UI can translate its own labels with Paraglide, but API responses also contain text shown directly to users such as provider names and configuration guidance, validation errors, etc. A translated page therefore still mixes languages when these strings come from English provider manifests or Go literals. Scattered Go strings also make translation review and handoff difficult.

The intended long-term boundary is any user-facing API response data or error. This proposal specifies the first slice: auth and model provider information and their closely related local auth and SCIM administration responses. It establishes the initial reusable backend catalog and locale-selection rules.

## Goals

- Localize Obot-owned auth/model provider, local auth, and SCIM administration messages from files translators can edit without changing Go source.
- Use standard `Accept-Language` negotiation, with English defaults and field-level fallback for incomplete translations.
- Permit new BCP 47 locales in backend catalogs and provider YAML without adding a hardcoded backend allowlist.
- Preserve response shape, stable identifiers, status codes, and diagnostic data while changing only human-facing copy.
- Give future API localization work a reusable message structure, request-locale, and response-boundary pattern.
- Return translated provider display names, descriptions, and configuration parameter labels/descriptions on provider list and detail responses when available.

## Non-goals

- Localizing every API endpoint in this proposal, ideally done in readable chunks.
- Making the UI language picker automatically list every locale present in backend catalogs or provider YAML.
- Changing the provider registry's reload mechanism or requiring backend rebuilds for YAML-only translations.

## Context and constraints

The existing UI sends its Paraglide locale in `Accept-Language`; its language picker currently lists `en`, `ja`, `ko`, and `zh-CN` separately from backend locale discovery.

Backend i18n changes require a Go rebuild; provider YAML follows the existing registry reload path.

## Proposed design

### Ownership and authoring

Translation objects contain only display fields; no localized command, parameter identifier, entitlement, secret flag, or other operational property is accepted. The public response resolves the requested values to the appropriate locale, if available, or falls back to English.

For Obot-owned strings in the server-side layer, similarly to UI, these will be contained/owned in the `pkg/i18n/messages` directory, where they are separated by feature and locale.

Example:

```
- messages
    - en.json # the root file containing core or common Obot instructional/validation/error strings
    - jp.json
    - localauth
        - en.json # containing Obot strings specific to localauth layer
        - jp.json
        - ...
    - auth-providers
        - en.json # containing Obot strings specific to auth-providers layer
        - jp.json
        - ...
```

Obot-owned strings use stable keys in `pkg/i18n/messages/{area}/{locale}.json`, with English as the required source. Keys must be unique across files for a locale, and translated placeholders must match the English source. Missing or empty translations fall back to English. Local auth provider metadata and Okta SCIM-generated parameter guidance read from this catalog instead of embedding translatable prose in Go. For consistency, product terms and navigation labels should be reviewed against UI terminology.

For auth/model providers, the provider manifests will update the appropriate `name`, `description`, `friendlyName`, and parameter `description` values to handlebar variables that will match to an appropriate `{area}/{locale}.json` key/value pair.

Example:

```
    name: "${google_auth_provider_name}"
    command: "google-auth-provider/bin/obot-provider"
    icon: "/admin/assets/google_icon_small.png"
    iconDark: "/admin/assets/google_icon_small.png"
    description: "${google_auth_provider_description}"
    link: "https://google.com/"
    requiredConfigurationParameters:
    - name: "OBOT_GOOGLE_AUTH_PROVIDER_CLIENT_ID"
        friendlyName: "${google_auth_provider_client_id_friendly_name}"
        description: "${google_auth_provider_client_id_description}"
    ...
```

### Request and response contract

The API parses `Accept-Language` weights and selects one positive-weight locale from backend catalog locales. It tries the requested tag and its parents, then a compatible base language/script, and defaults to `en` for absent, invalid, or unsupported input. A provider list will supply the handlebar variables that need to be filled with the selected locale or return empty if the key/value pair is not found. Fields without text for the selected locale use their English value. The response adds `Vary: Accept-Language` wherever its language can vary.

Localization runs on a copy of the served manifest/parameter data at the API boundary, after effective provider parameters have been calculated. Persisted provider resources, provider process configuration, and status computation remain language neutral. Errors with application-authored text render a message key using the request locale; dynamic names/counts are arguments. Background calls without a request locale use English. Raw errors from external providers will not be translated.

### Completion criteria for this slice

Initial implemenation will knock out: auth/model provider YAML localization, local auth and SCIM API messages.

## Alternatives considered

### Moving all auth/model provider yamls to the frontend

Decided against because existing behavior allows self-hosted Obot users to point to their own auth/model providers repository. In general, it is more of a lift and loss of flexibility when changes can be minimal with adding `locales` into the existing yaml files.

## Trade-offs

The two authoring locations match ownership, but it is recommended translators review JSON catalogs and provider YAML. Catalogs embedded in Go are easy to ship and validate but require a backend release for copy changes.

## Risks and open questions

Not applicable.

## Rollout and migration

The work spans three repositories. Update provider manifests in `/enterprise-providers` and `/providers` to handlebar variables where necessary (name, description, friendlyName, etc). These changes should be merged before the backend changes to obot. There shouldn't be any need to do a migration.

## Testing and validation

- Test auth/model provider list and detail responses with translated metadata and parameters, including effective SCIM parameters; assert the persisted manifest is unchanged.
- Test local auth, provider-operation, and SCIM setup/enforcement messages through API paths in at least one non-English locale; assert status codes and structured response fields remain stable.

## References

- [ODP template](https://github.com/obot-platform/obot-design-proposals/blob/main/templates/design-proposal.md)
- [Obot design proposal process](https://github.com/obot-platform/obot-design-proposals)
- Implementation repositories: [Obot](https://github.com/obot-platform/obot), [providers](https://github.com/obot-platform/providers), [enterprise-providers](https://github.com/obot-platform/enterprise-providers)
