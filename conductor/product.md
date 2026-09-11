# Product: SparrowKit

## Product need: safe environment-specific console credentials

SparrowKit developers need one local `/sparrowkit` workflow for preparing the
credentials their application uses in development and after deployment. They
must be able to tell which environment they are editing, without copying
secrets between files or accidentally exercising production configuration from
their workstation.

The control panel remains development-only and local-only. Its production tab
means “edit the production credential file for deployment”; it does not make
the panel available in a production process and it must not run tests, send
mail, establish sessions, or call providers with production configuration.

### Product guardrails

- Development credentials are `config/credentials/development.yml.enc`.
- Production credentials are `config/credentials/production.yml.enc`.
- A target is selected only from a server-side allow-list. No selected target
  may fall back to `credentials.yml.enc` or to the other environment.
- The console never creates, returns, displays, logs, or otherwise exposes an
  encryption key or decrypted secret.
- Existing navigation and configuration forms retain the selected target.

### Out of scope

- Enabling `/sparrowkit` outside local development.
- Creating credential files or encryption keys, or changing key deployment.
- Changing runtime configuration loading, provider integrations, or customer
  application flows.
- Running production-target tests, mail delivery, sign-in harnesses, payments,
  or any other execution action from the console.

## Change record

- 2026-09-10 — Added the environment-specific credential-console need and its
  guardrails. This records the approved requirement for Track 01 and keeps the
  control panel’s local-development safety boundary intact.
