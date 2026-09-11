# Track 01: Environment-Specific Credential Tabs

## Customer problem

A developer configuring SparrowKit needs to prepare both local-development and
deployed-production credentials from the familiar local control panel. Today a
single credential context makes it too easy to edit or test the wrong
configuration. They need a clear, persistent environment selection that never
mixes files or reveals secrets.

This track delivers the need recorded in `conductor/product.md` under “safe
environment-specific console credentials.”

## Outcome

The development-only, loopback-only `/sparrowkit` console has a shared,
accessible Development/Production tab UI. Development reads and saves only
`config/credentials/development.yml.enc`; Production reads and saves only
`config/credentials/production.yml.enc`. Production is configuration-save-only
and cannot execute provider-facing or local test actions.

## Acceptance criteria

1. `/sparrowkit` remains unavailable outside Rails development and remains
   protected by the existing loopback/local-host gate. Selecting Production
   does not change that boundary.
2. Every hub and installed-panel page exposes the same keyboard-operable tab
   control, identifies the selected target to assistive technology, and
   preserves the active target through links, form submissions, validation
   failures, and redirects.
3. A Development request reads and writes only
   `config/credentials/development.yml.enc`. A Production request reads and
   writes only `config/credentials/production.yml.enc`.
4. Target selection is server-side allow-listed. Missing, forged, malformed,
   or unsupported target values fail closed: no credential file is read or
   written and the response gives a safe, target-neutral error.
5. A missing or unusable target-specific file/key, invalid ciphertext, or
   unreadable target-specific credential store prevents a write to either
   target. The developer receives a safe, target-specific recovery message;
   there is no fallback to `config/credentials.yml.enc` or the other target.
6. The console does not create credential files or encryption keys, expose key
   paths or key material, or expose decrypted secrets in HTML, logs, errors,
   flashes, redirects, or test output. Existing secret masking and
   blank-secret-retains-stored-value behavior apply to both targets.
7. Production permits configuration saves only. Test email, sign-in harness,
   payment/provider actions, and every comparable execution endpoint are
   absent or rejected for Production, including direct forged POST requests.
8. Existing Development behavior and target-free navigation/forms continue to
   work under the Development target without changing their configured values.
9. Automated coverage proves isolated reads and writes using distinct target
   fixtures; persistence across hub, Auth, Mail, and Pay navigation/forms;
   fail-closed target validation; missing-key, unreadable-file, and invalid
   ciphertext no-write cases; secret masking; production-action rejection; and
   the existing console gate and CSRF protections.
10. The relevant gem suites, `standardrb`, RuboCop, Brakeman, documentation
    specs, and the repository rake gate pass before approval.

## Out of scope

- Making the console accessible in production or from non-loopback hosts.
- Generating, copying, storing, showing, or rotating credential keys.
- Fallback support for `config/credentials.yml.enc` or cross-target reads.
- Running any Production-target verification, test delivery, sign-in,
  provider, payment, or webhook operation.
- Altering runtime credential precedence, production deployment procedures, or
  application-facing authentication, mail, or billing behavior.

## Dependencies and risks

- The feature writes encrypted configuration and can target production
  deployment credentials, so security review must define fail-closed target
  resolution, secret-safe errors/logging, and the hard block on Production
  execution before implementation begins.
- Rails encrypted-credential APIs may memoize configuration. The implementation
  must keep target reads isolated and must not let a process-level cache select
  the wrong file after a tab change.
- Installed Auth, Mail, and Pay panels have independent routes and actions;
  shared target propagation must cover every registered panel without breaking
  their existing forms or navigation.

## Quality gate

Do not approve until every acceptance criterion is verified, the required
handoffs are recorded in `plan.md`, the security decision is implemented, and
all checks in criterion 10 pass.
