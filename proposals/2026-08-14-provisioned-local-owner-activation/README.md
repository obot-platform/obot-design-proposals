# 2026-08-14: Set up the first Local auth owner from deployment settings

- **Authors:** @cjellick
- **Created:** 2026-08-14

## Summary

Add a way for our provisioning system to set the first Local auth owner and send that owner a password setup link. Obot will configure the Local auth provider, create the owner without a usable password, and store a hash of the setup token instead of the token itself.

When the user opens the link, Obot will give them a session limited to setting a password or signing out. The user will have to set a password before using the rest of Obot.

The link will work until it expires or the user sets a password, so the user can open it again if they leave before finishing. A new token from our provisioning system will replace a pending token. After the user sets a password, changing the owner email or setup token in deployment settings will not create a new setup link or change the user's password.

Because provisioned trials will start with Local auth, Obot will also let the owner configure and test a replacement provider before disabling Local. Initial owner setup will not be enabled for provisioned trials until this provider switch is available.

## Related issues

- [obot-platform/obot#7565](https://github.com/obot-platform/obot/issues/7565) — Main issue for creating a trial with an initial owner and a password setup link, without asking the user to configure an auth provider first.
- [obot-platform/obot#4604](https://github.com/obot-platform/obot/issues/4604) — Earlier work on the bootstrap flow for setting up the first auth provider and owner.

## Related ODPs

None.

## Problem and motivation

Our provisioning system creates trial environments for a known user's email address. Today it sends the user a bootstrap token. The user signs in as the bootstrap user, chooses an auth provider, configures it, and sets up an owner before they can evaluate Obot. **We want to completely eliminate setting up an auth provider as a point of friction and get the user directly into doing something useful with Obot.**

An initial password would still make the user copy a credential into a login form and then change it. A setup link would take the user from the trial email directly to the page where they choose the password they will use.

The link must only work for the owner chosen by our provisioning system. A visitor who only knows the environment URL or the owner's email must not be able to set the password. The user must also be able to leave the page and return later if they don't finish setup the first time.

## Goals

- Let our provisioning system choose the first owner without asking the user to use a bootstrap token or an initial password.
- Require a random setup token tied to that owner. Knowing the email or environment URL isn't enough.
- Require the owner to set a password before using Obot.
- Let the owner reopen the link until setup succeeds or the link expires.
- Let our provisioning system replace a pending setup token.
- Require a password change by default when an administrator creates a Local user or resets a Local user's password.
- Let the owner switch from Local auth to another provider without using a bootstrap token or losing access during the switch.
- Work with Docker, Helm, restarts, and multiple Obot server replicas.
- Keep existing deployments and Local users working as they do today.

## Non-goals

- Account recovery after the first owner finishes setup.
- Password recovery by email or optional password changes for Local users.
- Creating more than one initial owner from deployment settings.
- Creating other Local users from deployment settings.
- Moving Local users or their work to a new Obot user when the auth provider changes.
- Changing how external auth providers assign Obot roles.
- Protecting a setup link after someone gains access to the provisioning system, the deployment Secret, or the user's email account.

## Context and constraints

Obot currently uses one configured login provider at a time. The Local provider stores its users and sessions in the Obot database. It hashes passwords with Argon2id and puts the session token in a cookie that browser scripts cannot read.

The bootstrap token is an Owner credential used to set up authentication or recover access. Obot can generate it or read it from `OBOT_BOOTSTRAP_TOKEN`.

## Proposed design

If this proposal is accepted, Obot and our provisioning system will work as described below.

### Deployment settings

The provisioning system will enable this mode with:

```text
OBOT_SERVER_LOCAL_AUTH_INITIAL_OWNER_EMAIL=owner@example.com
OBOT_SERVER_LOCAL_AUTH_INITIAL_OWNER_SETUP_TOKEN=<random token>
```

`OBOT_SERVER_ENABLE_AUTHENTICATION` must also be `true`. The email and token must be set together. `OBOT_SERVER_LOCAL_AUTH_INITIAL_OWNER_SETUP_TOKEN_EXPIRATION_HOURS` sets how long the link works and defaults to 168 hours.

The provisioning system must create a different random token for each environment. The token must contain at least 256 bits of randomness, which makes guessing it impractical. The documented command is `openssl rand -hex 32`.

For Helm, the email and expiration will go under `config`, while the token will go under `secret`:

```yaml
config:
  OBOT_SERVER_ENABLE_AUTHENTICATION: "true"
  OBOT_SERVER_LOCAL_AUTH_INITIAL_OWNER_EMAIL: "owner@example.com"
  OBOT_SERVER_LOCAL_AUTH_INITIAL_OWNER_SETUP_TOKEN_EXPIRATION_HOURS: "168"
secret:
  OBOT_SERVER_LOCAL_AUTH_INITIAL_OWNER_SETUP_TOKEN: "<random token>"
```

The chart will reject the token if it is placed in the ConfigMap. It will not generate a bootstrap token when a setup token is set. If the chart uses an existing Kubernetes Secret, that Secret must contain the setup token.

This draft proposes keeping bootstrap for deployments that do not use these settings. If both initial owner settings and `OBOT_BOOTSTRAP_TOKEN` are set, initial owner setup will take priority. Obot will disable bootstrap login, ignore the bootstrap token, and write a warning to the log. Whether startup should reject this combination instead is an open question below.

If Local auth is not configured, Obot will configure it and allow the owner's email domain. For example, `owner@example.com` will allow Local users from `example.com`. An administrator can change the allowed domains later. If Local auth is already configured and does not allow the owner's email, startup will fail instead of creating an account that cannot sign in.

If another auth provider is already configured when Obot starts, Obot will leave it in place and skip initial owner setup. This will make it safe to leave the initial owner settings in place after a provider switch is complete.

The settings still cause a problem during the switch. If no provider is configured, a restart configures Local again. Disabling Local also signs out the Local owner before they can configure the replacement provider. The staged provider switch described below will prevent this lockout.

Obot will add the owner email to its existing list of owner emails. The first Obot user created from that email will receive the Owner role.

### Switching away from Local auth

This proposal will add a staged provider switch. Local auth will remain active while the owner configures and tests one replacement provider. Normal login will continue to use Local auth until the switch is complete.

The same flow will work when switching between any two auth providers. The current provider will remain active while the owner configures and tests its replacement. This proposal needs the flow for switching away from Local auth, but the API and provider states will not be limited to Local auth.

Each auth provider configuration will have an `active` or `staged` state. Obot will allow one active provider and at most one staged provider. Existing provider configurations will be treated as active. A staged provider will have saved settings and can run for the test login, but it will not appear as the current login provider or accept normal login requests.

The API will support three steps:

1. `POST /api/auth-providers/{id}/stage` will save the replacement provider settings without disabling Local auth.
2. `POST /api/auth-providers/{id}/verify` will start a one-time login with the staged provider. The request will be tied to the signed-in Owner who started the switch. The returned identity must receive the Owner role under the normal role rules.
3. `POST /api/auth-providers/{id}/activate` will make the verified provider active and disable Local auth as one operation. The user will finish the switch signed in through the replacement provider.

If setup, verification, or activation fails, Local auth will remain active. The owner can edit or remove the staged provider and try again. A restart will also keep Local active while a staged provider exists. Obot will not support several providers for normal login as part of this proposal.

This proposal will not move Local users to the replacement provider. The Local user management page and the provider switch confirmation will warn that signing in through the new provider can create a new Obot user and that Local users and their work will not transfer.

Initial owner setup will not be enabled for provisioned trials until this staged switch is implemented.

### Data stored by Obot

Local users will get these fields:

```text
require_password_change  boolean, default false
setup_token_hash         string, indexed
setup_token_expires_at   nullable timestamp
```

Obot will store a SHA-256 hash of the setup token. A hash is a one-way value used to check a token without storing the token. SHA-256 is suitable here because the input will be a random 256-bit token rather than a password chosen by a person.

The first owner will start with a random password hash that cannot be used to sign in. The user will also have `require_password_change=true`, the setup token hash, and the time when the token expires.

Startup will follow these rules:

- Starting Obot again with the same token does not change or extend its expiration time.
- A new token replaces the old token while setup is pending and signs out every session belonging to the pending user.
- A different token is required to replace an expired token.
- After setup is complete, deployment settings cannot create another setup token or change the password.
- If a Local user with the same email already exists without a setup token, Obot does not change that user and writes a warning to the log.

Obot will rely on the existing unique database index on `hashed_email` to protect against setup races when several replicas start at the same time. The startup code will handle a duplicate insert by loading the user created by the other replica instead of failing.

Replacing a setup token and deleting every session belonging to the pending user will happen in one database transaction. This means either both changes will be saved or neither change will be saved.

### Setup link

The provisioning system will send this link:

```text
https://trial.example/activate#token=<random token>
```

The token will come after `#`, in the URL fragment. Browsers do not send this part of the URL to the web server or include it in the `Referer` header. The setup page will read the token and immediately remove it from the address bar and browser history. The page will not load scripts from other sites.

`/activate` will be a public page. A profile request that returns 401 must not redirect the browser away from this page because that would discard the token before it is used.

The page will send only the token to `POST /api/local-auth/activate`. It will not send an email or user ID. The server will hash the token, find an unexpired user who still needs to set a password, and create a Local session. Invalid, expired, and completed tokens will all return the same response. The page will show that error without using the application's normal 401 redirect.

Obot's existing limit for requests from signed out users will apply to this endpoint and track requests by IP address. The random token will be the main protection against guessing.

Opening the link will not use it up. The user can open it again to create another limited session until the link expires or one session sets the password. This will let the user leave and return later.

### Session limits and password setup

On every request made with a Local session, Obot will read whether the Local user still needs to change their password. The server will block access to the application until the password is set. A redirect in the UI will help the user get to the right page, but the server check will prevent access.

The limited session will be able to use only:

- the password page and its images, styles, and scripts;
- sign out;
- `GET /api/me` and the read-only version, license, and application preference requests needed to draw the page; and
- `POST /api/local-auth/change-password`.

Other pages will redirect to the password page. Other API requests will return 403. Obot will still record denied API requests in the audit log and send any updated session cookie.

The password endpoint will get the Local user and current session from the request. The request cannot choose another email, user ID, or role. The endpoint will check and hash the new password. It will then make all of these changes together: change `require_password_change` from true to false, delete the setup token, sign out every other session, and keep the session that set the password. If any change fails, none of the changes will be saved.

The database update will succeed only while `require_password_change` is true. If two setup sessions submit different passwords at the same time, the first update will succeed and the second update will fail. The second session cannot replace the password chosen by the first session.

When an administrator creates a Local user or resets a Local password, the UI will require a password change by default and let the administrator turn that requirement off. The UI will show which users still need to change their password. Any password set by an administrator will also delete an unused initial owner setup token.

### Leaving setup and recovering access

- If the user leaves before setting a password, they can open the same link again while it is valid. They can also choose **Finish later**, which signs them out without using up the link.
- If the link is lost, exposed, or expired while setup is pending, the provisioning system creates a new token, updates the deployment Secret, restarts every replica with the same token, and sends a new link.
- If setup is complete, an administrator can use the existing Local user password reset screen. Deployment settings cannot reset the account.
- If no administrator can sign in, an operator can remove both initial owner settings, set a new `OBOT_BOOTSTRAP_TOKEN`, turn on the existing forced bootstrap option, and restart Obot. This recovery action must be done on purpose; Obot does not fall back to it by itself.

## Security risks and protections

| Risk | How the design handles it |
| --- | --- |
| A visitor knows the owner email | The visitor also needs the random token tied to that owner. There is no API that accepts only an email to start setup. |
| The token appears in proxy or server request logs | The link puts the token after `#`, which browsers do not send in the first HTTP request. The page later sends the token in a request body. We accept any remaining logging risk because the token is temporary and using a link makes setup easier for the user. |
| A setup session tries to use Obot before setting a password | The server allows only the password setup requests listed above. |
| The user closes the page | The link can be opened again until setup succeeds or expires. |
| Someone uses the link after setup | Setting the password deletes the token and signs out other setup sessions. |
| Two people use the link at the same time | Only the first password update succeeds. Possession of the link is still enough to win this race, so the email must be protected. |
| An administrator resets the password while the link is unused | Every administrator password reset deletes the setup token. |
| Deployment settings change after setup | A completed account cannot be put back into setup or have its password changed by these settings. |
| The provisioning system creates a weak token | The contract requires 256 bits from a secure random number generator. The length check is only a basic check. |

Anyone who gets a valid link can finish setup before the intended owner. The setup link works like a password reset link; it is not a second form of proof. The provisioning system must store the token as a secret, use an HTTPS URL, and send the email through an appropriate service.

## Alternatives considered

| Option | Why it was not chosen |
| --- | --- |
| Set an initial password | The provisioning system would need to create, store, and send a password. The user would need to copy it into the login page and then change it. This adds steps without improving the trial experience. |
| Let the user enter an email to start setup | The environment URL and owner email would be enough to set the password. A visitor who knows both could take the account. |
| Use the link only once | Using up the link when it creates the first browser session would prevent reuse, but it would leave users stuck if they close the tab, clear their cookies, or hit a browser error before setting a password. This proposal uses up the link when the password is set instead. |
| Keep using the bootstrap token for trials | This keeps the current process, including the step where the user chooses and configures an auth provider before evaluating Obot. It does not meet the goal of this proposal. |
| Keep a bootstrap token available for provider switching | This would preserve the current switching process, but the user would still need to keep or request a bootstrap token. The staged switch removes that step. |
| Support several active auth providers | This would require a default provider, a login choice, and changes to session handling. The staged switch solves the lockout without adding several normal login options. |
| Send the email from Obot | Obot would need email server settings, templates, retry behavior, and delivery status. The provisioning system already has the environment URL and the user's email address, so it sends the link. |

## Trade-offs

Obot gains a second type of setup token and a server check that limits what some Local sessions can do. New requests that every page makes must either work when denied or be added to the small list of requests allowed during password setup.

Allowing the link to be opened more than once makes setup easier to resume, but the link remains sensitive until the password is set. Expiration, token replacement, the limited session, and the rule that only the first password update succeeds reduce this risk.

The first Local provider configuration allows only the owner's email domain. This is safer than allowing every domain, but it may surprise users who later want Local users from other domains.

## Risks and open questions

Biggest risk: The staged auth provider switch will prevent the owner from being locked out, but it will not move Local users to the replacement provider. Each provider login is stored as a separate identity linked to an Obot user. Signing in through the replacement provider can create a new Obot user that does not have access to things the Local user set up, such as MCP servers. General user mapping is deferred. We can address that when and if it becomes an issue. The Local provider will continue to be described as intended for development and evaluation.

### Other questions

- **Do we keep bootstrap tokens?** This draft keeps bootstrap for deployments that do not use initial owner setup and for account recovery by an operator. The setup link replaces bootstrap only for provisioned trials.
- **What happens if both bootstrap and initial owner settings are present?** They must not create two usable Owner credentials. This draft gives initial owner setup priority, disables bootstrap, ignores `OBOT_BOOTSTRAP_TOKEN`, and logs a warning.
- **Can replicas running different Obot versions handle setup safely?** An older replica does not know about the password requirement and could let a setup session use the application. Every replica must be upgraded before the initial owner settings are added. This is a minor concern and may only need a release note.
- **Can an old Secret replace a newer setup token?** During a token change, a replica that restarts with the old Secret can write the old token hash back to the database. The first version of this feature requires every replica to receive the same Secret and restart as one planned change. We just won't support this and note it as a limitation.
- **What should we record about failed setup attempts?** Repeated failures may show that someone is guessing tokens. Logs and monitoring should count failures without recording the token or owner email.

## Rollout and migration

Upgrade and rollback are minor concerns for this proposal. It is unlikely that an installation will enable this feature during an upgrade while running several Obot replicas, and Obot generally discourages rolling back. The steps below cover these cases if they happen.

The database will add new columns with defaults that keep existing Local users unchanged. Existing administrator API clients that do not send the new password change option will get the new default: the user must change the password. Clients can send `false` to turn it off.

If an installation with more than one Obot replica enables this feature during an upgrade:

1. Upgrade every replica without adding the initial owner settings.
2. After every old replica is gone, add the owner email and setup token and restart every replica with the same settings.

A new trial with one replica can use initial owner setup on its first start. An existing installation does not replace an external provider or change an existing Local user.

Removing the initial owner settings stops the startup checks but does not delete the Local user or password. If a rollback is required, make sure no user still needs to change a password before going back to an older Obot version. An older version would not limit that user's session. If setup is still pending, replace the token to sign out setup sessions, stop every replica running the new version, and enable bootstrap recovery if needed.

## Testing and validation

- Test invalid settings, email formatting, allowed domains, repeated restarts, expiration, token replacement, completed accounts, existing users, and several replicas starting at the same time.
- Test that an old token stops working after replacement, every session belonging to the pending user is deleted, the same link can be opened again while pending, and only one password update can succeed.
- Test that invalid, expired, and completed links return the same error. Test that the password request can change only the signed in Local user and follows the password rules.
- Test every request allowed during password setup. Test that other requests are denied, written to the audit log, and still receive updated cookies.
- In a browser, start with `/activate#token=...`, check that the token is removed from the URL, and test invalid links, **Finish later**, reopening the link, Local login with a required password change, and access after completion.
- Test Helm with Secrets managed by the chart and existing Secrets, matching email and token settings, a token placed in the ConfigMap, bootstrap behavior, installation notes, and upgrades.
- Test several replicas with PostgreSQL. Start them at the same time, open the link through one replica, set the password through another, and replace the token on every replica.
- Test an upgrade where old and new replicas would otherwise run at the same time. Confirm that initial owner setup is not enabled until the old replicas are gone, and test the rollback steps above.
- Test staging, verifying, activating, editing, and removing a replacement auth provider while Local auth remains active. Test failures and restarts at every step.
- Test that activation requires a verified Owner, disables Local only after verification succeeds, and leaves the user signed in through the replacement provider.
- Test the user transfer warnings on the Local user management page and provider switch confirmation.

## References

None
