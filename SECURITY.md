# Security

## Reporting a vulnerability

**Report it to humans@sparrowsoft.co.** Please do not open a public issue.

Reports are acknowledged within two working days. If the report is valid you
will hear what the fix is and when it will ship, and you will be credited in
the release notes unless you would rather not be.

## What is in scope

Anything in the gems under `gems/`. In particular:

- Authentication and session handling in `sparrow_auth`
- Tenant isolation — any way to read or write another organization's rows
- The invitation flow, especially any way to be seated at a role nobody offered
- Anything in the control panel reachable from outside local development

## What is not

- The control panel (`sparrow_ui`) is development-only and refuses non-local
  requests before routing. It must never be in a production bundle; if it is,
  that is a deployment mistake rather than a vulnerability here.
- Deciding what a role may do. SparrowKit stores role names and does not
  interpret them, so authorization rules live in the application.

## What the tests are worth

Security claims in the READMEs are backed by the test suite, and the ones
easiest to get subtly wrong are additionally mutation tested — the guard was
deliberately broken to confirm a test goes red. A test that passes whether or
not the protection exists is worse than no test, because it is believed.
