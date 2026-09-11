# Plan: Environment-Specific Credential Tabs

## Phase 1 — Security Review (Agent: security-engineer)

- [x] Define the authoritative Development/Production target allow-list and
  fail-closed handling for missing, forged, malformed, and unsupported values.
- [x] Review target-specific encrypted credential access for key/file/ciphertext
  failures; specify safe errors and the no-read/no-write/no-fallback contract.
- [x] Confirm secret/key redaction boundaries for views, logs, errors, flashes,
  redirects, and automated coverage.
- [x] Identify every current execution endpoint and require server-side
  rejection for Production-target requests, including direct POSTs.
- [x] Record security acceptance evidence and a handoff to software-engineer.

## Phase 2 — Credential Target Implementation (Agent: software-engineer)

- [x] Implement the security-approved target resolver and isolated,
  target-specific credential read/write behavior.
- [x] Integrate target propagation and Production action refusal across the hub
  and registered Auth, Mail, and Pay panel endpoints without changing runtime
  credential behavior.
- [x] Add focused request/service coverage for target isolation, fail-closed
  failures, no-write failures, redaction, and action rejection.
- [x] Record implementation evidence and a handoff to ui-engineer.

## Phase 3 — Shared Tab Interface (Agent: ui-engineer)

- [ ] Add the shared accessible Development/Production tabs to the console
  layout and preserve the selected target through all console navigation,
  forms, validation failures, and redirects.
- [ ] Make Production visibly configuration-save-only and remove/disable every
  execution affordance while relying on the server-side block as enforcement.
- [ ] Test keyboard operation and the 375px mobile layout; record the UI
  evidence and a handoff to ux-designer.

## Phase 4 — UX Review (Agent: ux-designer)

- [ ] Review the target-selection and save-only flow at 375px first, including
  keyboard navigation, labels, validation recovery, and the risk of selecting
  the wrong environment.
- [ ] Write findings and disposition in `## UX Review`; hand off to ui-designer.

## Phase 5 — UI Design Review (Agent: ui-designer)

- [ ] Read `## UX Review` first, then review visual hierarchy, tab state,
  responsive consistency, and the Production configuration-only treatment.
- [ ] Write findings and disposition in `## UI Design Review` without changing
  the UX review section.

## Handoff — Project Manager to Security Engineer

**Next agent:** `security-engineer`.

**Why:** This feature selects and writes encrypted development or production
credential stores. Before code is designed, security must establish the
server-side allow-list, failure behavior, redaction boundaries, and an
unbypassable Production execution block. No implementation work may begin
until that review is recorded above.

**Approved inputs:** The console remains development-only and loopback-only;
Development maps only to `config/credentials/development.yml.enc`; Production
maps only to `config/credentials/production.yml.enc`; there is no fallback,
key creation, or key/secret exposure; Production is save-only.

<!-- security-engineer writes its handoff below -->

## Security Handoff

### Approved security requirements

1. **Authoritative target resolver — HIGH if bypassed.** Accept exactly the
   canonical request values `development` and `production`; map them through an
   immutable, server-owned table to exactly
   `config/credentials/development.yml.enc` plus
   `config/credentials/development.key`, and
   `config/credentials/production.yml.enc` plus
   `config/credentials/production.key`, respectively. Do not derive a path,
   key name, environment name, or symbol from any request value. Resolve the target before creating a
   credential reader, inspecting credential state, running an action, or
   writing. Missing, blank, repeated/array, non-string, malformed, forged, or
   unsupported values receive the same target-neutral 422 response (for
   example, “Choose a supported credential target.”), with no flash echo of the
   supplied value and no credential read or write.

2. **Independent encrypted stores — HIGH if bypassed.** A selected target must
   instantiate its own encrypted-configuration object with only its explicitly
   mapped ciphertext and key paths. Do not use `Rails.application.credentials`,
   its configured `content_path`/`key_path`, `RAILS_MASTER_KEY`, a process-global cache, a
   development-to-production fallback, or `config/credentials.yml.enc`. A
   target switch must not reuse a decrypted tree from the previous target.
   Neither read nor write may create a credential file or key. Before every
   write, successfully open and decrypt the selected target and prepare the
   complete merged document in memory; a missing/unreadable file or key,
   invalid ciphertext, unsupported contents, or any encryption/write failure
   returns without changing either target. The unselected target must never be
   opened or modified.

3. **Safe failure contract — MEDIUM if incomplete.** Valid target failures may
   identify only the selected label (“Development credentials” or “Production
   credentials”) and a generic recovery action (“make that target available and
   reload”). They must not reveal file/key paths, environment-variable names,
   key material, ciphertext, decrypted values, exception messages, backtraces,
   or request values in HTML, redirects, flashes, logs, or test failures. This
   supersedes the current generic `Settings.not_writable_reason` wording for
   target-specific errors, because it currently names `config/master.key` and
   `RAILS_MASTER_KEY`.

4. **Secret preservation and redaction — HIGH if bypassed.** Continue applying
   the recursive `for_display` masking to the selected target only; never pass
   the decrypted tree to a view or redirect. Blank submitted secret fields mean
   “retain the stored secret in this target,” never clear, copy from the other
   target, or render a sentinel/value. New secret submissions must be excluded
   from Rails request logging and any controller/application logging; never log
   raw credential structures or provider exceptions that could include them.
   Notices and alerts must be constant/sanitized text, never interpolate
   credential values, parameters, exception messages, key paths, or ciphertext.

5. **Production is configuration-save-only — HIGH if bypassed.** Enforce this
   server-side after a valid target is resolved and before any side effect,
   using a shared default-deny execution guard rather than hiding buttons.
   Production allows only credential configuration saves. It must reject direct
   forged requests to the current execution routes: Auth `POST sign-in-as`,
   Mail `POST test`, and Mail `DELETE mailbox`; the same guard applies to every
   later provider-facing, test, harness, delivery, payment, webhook, or local
   execution route. Reject with a safe 422/403 response and do not query
   accounts, read mail deliveries, send mail, change sessions, touch caches, or
   alter credentials. Existing CSRF checks remain active on all browser writes;
   the production-target guard is additional enforcement, not a replacement.

6. **Coverage required before approval.** Request/service specs must prove
   separate fixtures and keys for both targets, no cross-target read/write or
   memoized reuse, invalid-target no-read/no-write behavior, and no-fallback
   behavior. For missing key, unreadable/missing ciphertext, invalid ciphertext,
   and failed write, assert checksums/contents of both stores are unchanged and
   the response/log capture contains no secret, key path/material, ciphertext,
   raw exception, or untrusted target echo. Cover blank-secret preservation for
   each target; direct Production requests to all three current execution
   routes; CSRF rejection; and the existing non-development/non-loopback gate.

### Findings

- **MEDIUM — current target-agnostic write failure exposes key-location
  details.** `Settings.not_writable_reason` currently includes the literal
  `config/master.key` path and `RAILS_MASTER_KEY`, and console controllers put
  it in flashes. In the new target editor, replace this response path with the
  safe target-specific failure contract above. Attack vector: anyone with local
  console access receives avoidable information about the host’s credential-key
  lookup. Required before merge.

- **HIGH — implementation must not use the process-default credentials object
  for target reads/writes.** The present `Settings` API uses
  `Rails.application.credentials`, which resolves the host’s default store and
  is memoized. Reusing it for tabs can write or display the wrong environment
  after a target switch. Required before merge: a separate, explicit resolver
  and target-bound reader/writer as specified above.

### Security acceptance evidence

- Reviewed the PM handoff and all acceptance criteria in
  `conductor/tracks/01-credential-target-tabs/spec.md`.
- Reviewed the existing encrypted-settings implementation in
  `gems/sparrow_ui/lib/sparrow_ui/console/settings.rb`, hub and installed-panel
  controllers, and console routes. Existing browser-write CSRF declarations
  are present; the console’s development and loopback gate remains mandatory.
- No application code or dependencies were changed in this phase. The listed
  findings are design requirements for implementation and must be resolved and
  demonstrated in the software-engineer handoff.

<!-- HANDOFF FROM security-engineer:
     Reviewed: Track 01 spec and PM handoff; console credential settings, hub/Auth/Mail/Pay controllers, routes, existing CSRF declarations, and loopback/development gate.
     Findings resolved: Security requirements and target isolation contract recorded; no code changes in this review phase.
     Open items: MEDIUM safe target-specific failure messages; HIGH explicit target-bound encrypted reader/writer and Production execution guard, all assigned to software-engineer for implementation and tests.
     Clear to proceed: YES -->

**Next agent:** `software-engineer`.

**Why:** The PM-approved feature now has the required fail-closed target,
redaction, no-write, and Production execution-block contract. Software
engineering must implement it and supply the required automated evidence before
the UI stage.

## Software Handoff

Implemented the approved two-target encrypted-credentials boundary.

- `credential_target` accepts only the exact strings `development` and
  `production`. An explicit valid value is persisted in the browser session;
  absent requests use only that previously validated selection. A missing,
  malformed, repeated, or unsupported value returns a target-neutral 422
  before any credential store is opened.
- Each settings operation creates a fresh explicit encrypted configuration for
  exactly one mapped pair:
  `config/credentials/development.yml.enc` + `development.key`, or
  `config/credentials/production.yml.enc` + `production.key`. It does not use
  `Rails.application.credentials`, its process cache, a master-key environment
  fallback, or the generic credentials store. Missing/unreadable files or keys,
  invalid ciphertext, and write failures leave both target stores unchanged and
  surface only the selected-label recovery message.
- Settings saves are merged and encrypted in memory before one target-file
  write. Pay's two top-level sections and Mail's legacy-stream migration now
  each use one target-bound write, preventing a partially completed save.
- Auth sign-in-as and Mail test-send/mailbox-clear reject Production-target
  POST/DELETE requests with a fixed 422 before account, mailbox, delivery,
  cache, or credential work. No existing Pay execution endpoint exists.
- Focused specs cover allow-list validation and session persistence, isolated
  reads/writes, masking and blank-secret preservation, missing-key/invalid-
  ciphertext/write-failure no-write cases, and direct Production action
  rejection for all three current execution routes. They use generated test
  values and do not assert or print real secret material.

Verification:

- Passed: `ruby -c` for all changed implementation and focused spec files.
- Passed: `git diff --check`.
- Blocked before execution: `bundle exec rspec` and `bundle exec standardrb`
  cannot resolve because the workspace lacks `rake (~> 13.0)`; Bundler reports
  no runnable `rspec`/`standardrb` executable. This is an environment
  dependency issue, not a test failure.

Supplemental test adjustment: existing Auth, Mail, and Pay console request
examples now create both their legacy runtime fixture and the explicit
Development encrypted-store fixture, then establish `credential_target=development`
through the hub before exercising target-free panel requests. This preserves
the new missing-target 422 contract while retaining the older examples'
Development-only intent.

Supplemental documentation adjustment: `gems/sparrow_ui/README.md` now names
the two encrypted files and their matching keys, explains the no-create and
no-fallback behavior, says keys are deployed separately and never committed,
and makes clear that Production values are save-only from the local console.
`git diff --check` passed. The documentation suite remains blocked by the same
missing Bundler dependency recorded above.

<!-- HANDOFF TO ui-engineer:
     Models/services complete: SparrowUi::Console::Settings target-bound encrypted credential store and CredentialTargeting request concern.
     Routes/endpoints exposed: Existing hub/Auth/Mail/Pay routes accept credential_target=development|production; a valid explicit target persists in session for subsequent target-free navigation.
     Data available to the view layer: credential_target helper returns the selected target with name, label, and production?; all panel Settings reads now use that request target.
     Anything UI should know: Add credential_target to all cross-panel links and settings forms. Production may submit configuration saves, but Auth sign-in-as and Mail test-send/mailbox-clear return a safe 422 even for direct requests, so hide or disable those affordances. -->

**Next agent:** `ui-engineer`.

**Why:** The server now owns target validation, persistence, isolated reads and
writes, and the Production execution block. UI can add the shared tab control
and propagate the target without becoming a security boundary.

## UI Engineering Handoff

Implemented the shared target interface against the completed server-side
`credential_target` contract.

- Every hub and installed panel now renders the same Development/Production
  target links. The selected target uses `aria-current="page"`; links remain
  ordinary keyboard-operable anchors and work without JavaScript.
- Hub, Auth, Mail, and Pay configuration forms submit the selected canonical
  target in a hidden field. Hub/module/back navigation includes the target so
  the selected store remains visible through navigation; the server session
  remains the redirect/re-render recovery boundary.
- Production renders an explicit configuration-save-only status message. The
  Auth sign-in harness and Mail test-delivery/mailbox controls are not rendered
  for Production. Server-side rejection remains the enforcement mechanism.
- No credential values, key paths, or secret data are added to the UI.
- Added shared-layout request assertions for both target links, selected-state
  announcement, target propagation to a module/configuration form, and the
  Production Mail execution-control suppression. Existing shared-layout tests
  now begin with the required Development target.

Verification:

- Passed: ERB parsing for all changed templates.
- Passed: `git diff --check`.
- Blocked: `bundle exec rspec spec/requests/layout_spec.rb`,
  `bundle exec rspec spec/requests/credential_target_spec.rb`, and
  `bundle exec standardrb` — the workspace has no installed bundle executables
  (including rake, rspec, standard, Rails).
- Blocked: `npm run build` — the local `tailwindcss` executable is not
  installed. The new utilities are already present in the committed compiled
  stylesheet; no generated CSS change is required for these classes.
- Mobile test: NO live browser/application test was possible without the Rails
  bundle. The target/header layout uses the existing wrapping flex layout and
  compact controls, but UX must validate it at 375px once dependencies are
  available.

<!-- HANDOFF TO ux-designer (reviews first) then ui-designer (reviews second):
     Views implemented: shared credential-target tabs and Production notice; console layout; hub; Auth, Mail, and Pay console panels
     Stimulus controllers: none
     Bootstrap components used: none (project uses existing Tailwind console styles)
     Custom SCSS added: none
     Mobile tested: NO — Rails/browser dependencies are unavailable
     Questions for designer: Confirm target-tab hierarchy and wrapping at 375px; confirm the Production config-only notice is sufficiently prominent. -->

**Next agent:** `ux-designer`.

**Why:** UX review is required first. It should validate the target-selection
and Production save-only flow at 375px, keyboard navigation, target retention
after validation recovery, and wrong-environment safeguards before UI design
review.

### UI Remediation After UX Review

- The shared selector now includes visible `Credentials` context, making clear
  that Development and Production select the encrypted credential store being
  edited rather than a console screen or runtime environment.
- Each target link now uses the existing `text-sm` 20px line height with
  `py-3` (12px above and below), producing a 44px high interactive area; its
  text plus `px-3` makes the width greater than 44px. The target group wraps
  with the header's existing responsive flex layout, so both choices remain
  present at phone width without horizontal scrolling.
- Updated the shared layout request spec to assert the visible label and the
  44px touch-target utility classes on both target links.
- Passed: ERB parsing and `git diff --check`.
- Still blocked: live/RSpec/standard/mobile verification because the required
  Rails/RSpec/standard executables are not installed. No CSS rebuild is needed:
  `px-3` and `py-3` are already present in the committed console stylesheet.

## UX Review — Environment-Specific Credential Tabs

### Disposition: approved — required UX changes resolved

### ✅ Approved

- The environment choice is present consistently on the hub and installed panels. It is an ordinary link-based navigation control, so it works without JavaScript and is reachable by keyboard; the current destination is announced with `aria-current="page"`.
- The selected target is carried through panel links and configuration forms, while the server retains a previously validated choice for redirects and validation recovery. A developer does not silently fall back to the other credential store.
- Production communicates the important operational boundary in plain language: "Production credentials: configuration saves only." Auth sign-in-as and Mail test-delivery/mailbox actions are absent for that target, rather than leaving a tempting but non-working primary action.
- Missing/unusable credential stores leave configuration controls disabled and use the safe, target-specific recovery message. The reviewed templates do not add a credential value, key path, or secret to the page.
- The selector now has visible `Credentials` context, so sighted developers can tell that Development and Production select the credential store being edited, not a console page or runtime mode.
- Each target link now provides a 44px-high touch target (`text-sm` 20px line height plus `py-3`), with more than 44px of width. The selector's wrapping container keeps both target choices available at phone width without horizontal scrolling.

### 🔧 Required Changes (must fix before merge)

- None. The two prior blockers are resolved in the shared selector.

### 💡 Suggestions

- If a configuration form has unsaved edits, warn before a target-switch link discards them. This is not merge-blocking, but it would prevent a long credential entry from disappearing when a developer checks the other environment.

### Terminology flags

- No blocking terminology issues. "Production credentials" and "configuration saves only" accurately describe the consequence of the selected target without implying that the console runs in production.

### Test limitations

- Re-reviewed the remediated shared ERB and the UI remediation handoff. A live 375px/browser and assistive-technology pass could not be run: this workspace lacks the installed Rails/RSpec/standard executables and Tailwind executable, as recorded in the UI handoff. Run the planned phone-width keyboard/touch verification once dependencies are available; this is a test-environment limitation, not a remaining UX design blocker.

## UI Design Review — Environment-Specific Credential Tabs

### Disposition: approved

### ✅ Approved

- The shared header control has an explicit `Credentials` label, so Development and Production read as credential-store choices rather than module navigation or a runtime-mode switch.
- The selected target is visually distinct through the console's established purple-on-slate current-state treatment: a tinted active surface plus purple type in both light and dark themes. Inactive targets remain neutral, and the same `aria-current="page"` attribute drives the visual state and the announced state.
- The selector matches the existing console language: Inter type, small medium-weight navigation text, slate borders and surfaces, purple interactive accents, and compact rounded controls. It does not introduce a competing component or ad-hoc color.
- Production's configuration-only message uses the existing amber warning-card treatment and sits before page content, making the environment boundary prominent without competing with the page heading or save controls.
- Each target anchor has `py-3` with the console's 20px small-text line height, yielding a 44px vertical touch target; `px-3` also keeps both controls wider than 44px. The selector and header use wrapping flex containers with no fixed width, preserving the choices at narrow widths rather than requiring horizontal scrolling.

### 🔧 Required Changes (must fix before merge)

- None.

### 💡 Suggestions (optional improvements)

- During the next live 375px pass, capture the wrapped header in each installed-module combination to keep future header additions from crowding the credential control. The current layout is appropriately flexible; this is a regression safeguard, not a design defect.

### Decision needed

- None.

### Test limitations

- Reviewed the rendered-component source, shared layout, compiled console utilities, and the UX-approved remediation. ERB parsing and `git diff --check` are recorded as passing in the UI handoff. A live browser/assistive-technology check at 375px could not run because this workspace lacks the Rails/RSpec/standard/Tailwind executables and no local browser is installed. This is an environment limitation, not a remaining visual blocker.

## Final Security Verification

### Disposition: NOT APPROVED — remediation required

Verified the implemented target resolver, all hub/Auth/Mail/Pay console
controllers and routes, shared target UI, focused specs, existing CSRF
declarations, and the development-plus-loopback gate.

### Verified controls

- The resolver accepts only `development` and `production`, rejects invalid
  request shapes before opening a store, and persists only an already validated
  target in the session.
- The selected target is mapped to fixed, target-specific ciphertext and key
  paths; no request value constructs a path, and reads use fresh target-bound
  configuration instances rather than `Rails.application.credentials`.
- The UI carries the selected target and removes Production execution controls.
  The server independently returns 422 before side effects for Auth
  `sign-in-as`, Mail `test`, and Mail `mailbox` direct Production requests.
- Target-unavailable responses use the selected label only and do not expose a
  path, key material, ciphertext, or underlying exception.

### Open findings

- **CRITICAL — credential values can be exposed through request logs and raw
  provider errors in flashes. Owner: software-engineer.** No
  `filter_parameters` configuration exists anywhere in the repository, while
  the credential forms submit names such as `api_key`, `private_key`, and
  `otp_secret`; ordinary Rails request logging can therefore record submitted
  credential values. Separately, Mail appends `result.error.message` and
  rescued `SparrowMail::Error#message` to its flash (`test_send`), and an
  existing request spec explicitly expects the raw provider text in that flash.
  Providers can echo credentials or request data in their errors, so a local
  developer who saves/tests a key can disclose it to application logs or HTML.
  Required fix: merge the console secret-name matcher into Rails parameter
  filtering without replacing host filters; replace raw provider-error flashes
  with the existing safe category text only; and add logger/response canary
  specs proving a submitted/generated secret and a provider error containing
  one are absent from logs, response bodies, and flashes. This blocks merge.

- **MEDIUM — target key handling is not Rails-compatible. Owner:
  software-engineer.** `TargetConfiguration#key` intentionally ignores the
  environment key, and `Store#opened_configuration` requires the target key
  file even when `RAILS_MASTER_KEY` is present. Rails resolves an encrypted
  configuration key from `RAILS_MASTER_KEY` first, then the explicitly
  configured key path. The console must preserve that key-source precedence
  for the explicitly selected ciphertext file; it must still never fall back to
  `config/master.key`, `config/credentials.yml.enc`, or the other target.
  Required fix: use Rails-compatible `RAILS_MASTER_KEY` resolution followed by
  only the selected target's explicit `.key` path, keep all failures sanitized,
  and add tests for an environment-key-only selected target and for precedence
  over a differing target key file. The earlier no-fallback rule applies to
  credential stores, not Rails' supported encryption-key source.

### Verification limitations

- Ruby syntax checks passed for the changed settings, targeting concern, and
  four console controllers.
- The recorded RSpec/standardrb gates remain unrun because the workspace has no
  installed Bundler executables/dependencies. This does not change the finding
  severity; the required remediation specs must run before approval.

<!-- HANDOFF FROM security-engineer:
     Reviewed: Implemented credential resolver, target-bound Settings store, CredentialTargeting concern, hub/Auth/Mail/Pay controllers and routes, shared target UI, focused specs, CSRF declarations, and loopback/development gate.
     Findings resolved: Strict target allow-list, target-bound file selection, safe target failures, and direct Production execution guards verified structurally.
     Open items: CRITICAL request-log/raw-provider-error credential exposure; MEDIUM Rails-compatible RAILS_MASTER_KEY precedence. Owner: software-engineer.
     Clear to proceed: NO -->

## Security Remediation — software-engineer

Resolved both final security findings.

- The Sparrow UI engine merges `Settings::SECRET_NAME` into the host's existing
  Rails `filter_parameters` list. It does not replace host filters. Credential
  form names such as `api_key`, `private_key`, `otp_secret`, and nested secret
  fields are now filtered before ordinary Rails request logging.
- Mail test-send feedback now uses only the existing safe category message.
  It never appends provider or rescued error messages to a flash or response.
- Target encryption now uses Rails' normal `RAILS_MASTER_KEY`-first lookup,
  followed by only the selected target's explicit `.key` path. Ciphertext paths
  remain fixed to the selected Development or Production file; there is no
  generic-store, other-target, or key-generation fallback.
- Added generated-canary regression coverage proving a submitted credential is
  filtered in actual request logs and absent from the response and flash;
  provider-error canaries are absent from Mail flashes and responses; and a
  selected target works from `RAILS_MASTER_KEY` alone and honors it over a
  differing selected key file.

Verification passed:

- `cd gems/sparrow_ui && bundle exec rspec spec/sparrow_ui/engine_spec.rb spec/sparrow_ui/console/credential_target_spec.rb spec/requests/credential_target_spec.rb`
  — 21 examples, 0 failures.
- `cd gems/sparrow_ui && bundle exec standardrb` — passed.
- `cd gems/sparrow_mail && bundle exec rspec spec/requests/console/test_send_spec.rb`
  — 18 examples, 0 failures.
- `cd gems/sparrow_mail && bundle exec standardrb` — passed.
- `bundle exec rake spec:docs` — 25 examples, 0 failures.
- `git diff --check` — passed.

<!-- HANDOFF TO security-engineer:
     Remediated: Rails request parameter filtering, provider-error redaction, and RAILS_MASTER_KEY precedence.
     Regression evidence: target settings/service and request logging specs, Mail test-send response/flash specs, all commands listed above.
     Please re-review: final security blockers and approve or identify remaining issues. -->

## Final Security Re-verification

### Disposition: APPROVED

Both prior blockers are resolved.

- **CRITICAL credential disclosure — resolved.** The Sparrow UI engine merges
  `Settings::SECRET_NAME` into, rather than replacing, host
  `filter_parameters`. The focused request spec captures ordinary Rails request
  logging and proves a generated credential canary is filtered and absent from
  the response and flash. Mail test-send now emits only category-safe failure
  text; canary provider errors are absent from its flash and response.
- **MEDIUM Rails key resolution — resolved.** Each store still selects only its
  fixed target ciphertext and fixed target key-file path, but now delegates key
  lookup to Rails with `RAILS_MASTER_KEY` precedence. The targeted service
  coverage proves a selected store can be read/written with only that
  environment key and that it overrides a differing selected key file. No
  generic credential store, `config/master.key`, other target, or generated key
  is used as a fallback.
- The earlier structural verification remains valid: strict request allow-list,
  isolated per-operation configurations, safe target-unavailable errors,
  existing CSRF and loopback/development gates, plus server-side 422 refusal of
  all current Production execution actions.

Independent verification passed:

- `cd gems/sparrow_ui && bundle exec rspec spec/sparrow_ui/engine_spec.rb
  spec/sparrow_ui/console/credential_target_spec.rb
  spec/requests/credential_target_spec.rb` — 21 examples, 0 failures.
- `cd gems/sparrow_ui && bundle exec standardrb` — passed.
- `cd gems/sparrow_mail && bundle exec rspec
  spec/requests/console/test_send_spec.rb` — 18 examples, 0 failures.
- `cd gems/sparrow_mail && bundle exec standardrb` — passed.
- `git diff --check` — passed.

<!-- HANDOFF FROM security-engineer:
     Reviewed: The two final remediation changes and their request/service coverage: Rails parameter filtering, Mail provider-error rendering, and selected-target RAILS_MASTER_KEY precedence.
     Findings resolved: CRITICAL credential exposure through request logs/raw Mail errors; MEDIUM non-Rails-compatible target key resolution.
     Open items: none.
     Clear to proceed: YES -->

## Mail Runtime Regression Follow-up — software-engineer

Root verification exposed four Mail console request regressions after target
selection became explicit. The console correctly wrote only
`config/credentials/development.yml.enc`, while the Mail dummy application was
still booting its runtime from an unrelated temporary credential store.

The dummy host now uses the explicit Development ciphertext and matching key
path as its Rails runtime credentials. This makes the existing post-save
`SparrowMail.apply_credentials!` integration examples exercise the selected
Development target, without adding a generic-store fallback to console code or
changing Production lockout behavior. The unavailable-target assertion now
expects the redacted, target-neutral-safe message rather than a master-key
detail, and the manual-location example reads the selected Development target.

Verification passed:

- `cd gems/sparrow_mail && bundle exec rspec spec/requests/console/sparrowkit_spec.rb:869 spec/requests/console/sparrowkit_spec.rb:947 spec/requests/console/sparrowkit_spec.rb:966 spec/requests/console/sparrowkit_spec.rb:983`
  — 4 examples, 0 failures.
- `cd gems/sparrow_mail && bundle exec rspec spec/requests/console/sparrowkit_spec.rb`
  — 74 examples, 0 failures.
- `cd gems/sparrow_mail && bundle exec standardrb` — passed.
- `git diff --check` — passed.

Generated dummy encrypted credential fixtures were moved out of the worktree
after verification; no key or ciphertext fixture is retained for commit.

<!-- HANDOFF TO ui-engineer:
     Backend integration complete: the Mail dummy runtime now reads the explicit Development credential target, so saved Development Mail settings are applied by the running app in request coverage.
     Controllers/routes: no new routes or controller/view contract changes.
     UI considerations: retain explicit credential_target on console requests; unavailable-target feedback deliberately omits key paths and key details.
     Verification: focused four-example regression run and full Mail sparrowkit request spec file pass (74 examples), plus standardrb and git diff --check.
     Next: ui-engineer may continue or revalidate UI integration; no UI-owned file was changed for this follow-up. -->

## Auth Runtime Regression Follow-up — software-engineer

Resolved the second root-gate regression set without adding a fallback to the
console. The Auth dummy host now uses the exact Development ciphertext and
matching key path that the selected Development console store writes. Its test
fixture resets only that target and clears Rails' runtime credentials cache when
an example deliberately models a fresh application boot.

The request and non-request specs now establish their target explicitly:

- Console guide/report examples run inside an explicit Development target
  context instead of allowing an unselected store to read.
- Every Auth sign-in-harness executable request sends
  `credential_target=development`. A successful sign-in rotates the Rails
  session, so relying on the prior session target would correctly fail closed
  on the next direct POST.
- Auth link and unavailable-store assertions now reflect the target-carrying
  route and redacted unavailable message.

No controller or production target-lockout behavior changed.

The initially observed `ActiveSupport::MessageEncryptor::InvalidMessage` and
schema-migration stack were fixture-environment residue: generated encrypted
credential ciphertext no longer matched its generated key. After moving those
uncommitted artifacts out of the worktree, the focused migration round-trip and
the full Auth suite both passed. No current pre-existing test failure remains.

Verification passed:

- `cd gems/sparrow_auth && bundle exec rspec spec/requests/console/sparrowkit_spec.rb:80 spec/requests/console/sparrowkit_spec.rb:212 spec/requests/console/sparrowkit_spec.rb:591 spec/requests/console/sparrowkit_spec.rb:682 spec/requests/console/sparrowkit_spec.rb:693 spec/requests/console/sparrowkit_spec.rb:703 spec/requests/console/sparrowkit_spec.rb:712 spec/requests/console/sign_in_harness_spec.rb:76 spec/requests/console/sign_in_harness_spec.rb:106 spec/console/guide_api_spec.rb:30 spec/console/guide_api_spec.rb:39 spec/console/guide_api_spec.rb:52 spec/console/guide_api_spec.rb:61 spec/console/guide_api_spec.rb:74 spec/schema_spec.rb:195`
  — 18 examples, 0 failures.
- `cd gems/sparrow_auth && bundle exec rspec` — 538 examples, 0 failures.
- `cd gems/sparrow_auth && bundle exec standardrb` — passed.
- `git diff --check` — passed.

Generated dummy encrypted credentials were moved out of the worktree after
testing; neither keys nor ciphertext fixtures remain for commit.

<!-- HANDOFF TO ui-engineer:
     Backend integration complete: Auth's dummy runtime uses the explicit Development credential target, and direct Auth harness posts retain an explicit target after session rotation.
     Controllers/routes: no new routes or controller behavior changes.
     UI considerations: console links/forms must preserve credential_target; a successful sign-in rotates the browser session, so subsequent direct executable requests must include it explicitly.
     Verification: focused Auth regression run (18 examples) and full SparrowAuth suite (538 examples) pass, plus standardrb and git diff --check.
     Next: ui-engineer may continue or revalidate UI integration; no UI-owned file was changed for this follow-up. -->

## Sparrow UI Test-Target Follow-up — software-engineer

Resolved the root-gate Sparrow UI failures caused by target-free test bootstrap.
The Sparrow UI dummy application's runtime credentials now point to the exact
explicit Development target. Request tests that exercise a successful console
response send `credential_target=development`; the dedicated missing and forged
target specs remain target-free and continue to prove fail-closed 422 behavior.
Direct Settings unit examples run inside an explicit Development target context.

Also fixed one actual Store regression: `move_and_write` previously returned
success and rewrote the encrypted file when no source subtree existed. It now
returns `false` unless a subtree moved or a nonempty update was supplied. Layout
assertions now recognize the target-aware root paths and the header's
whitespace-preserving rendered anchors.

Verification passed:

- `cd gems/sparrow_ui && bundle exec rspec` — 139 examples, 0 failures.
- `cd gems/sparrow_ui && bundle exec standardrb` — passed.
- `git diff --check` — passed.

Generated Sparrow UI dummy credentials were moved out of the worktree after
testing; no key or ciphertext fixture is retained for commit.

<!-- HANDOFF TO ui-engineer:
     Backend/test integration complete: Sparrow UI request/unit tests select Development explicitly where they expect a rendered or writable console; missing/forged selection coverage remains fail-closed.
     Behavior fix: no-op Settings subtree moves no longer report a write.
     UI considerations: root links use the mounted `/sparrowkit/` path with credential_target, and module anchors may include formatting whitespace.
     Verification: full Sparrow UI RSpec suite (139 examples), standardrb, and git diff --check pass.
     Next: ui-engineer may revalidate the target-aware navigation/UI contract; no new visual design decision was made here. -->

## Pay Runtime Regression Follow-up — software-engineer

Resolved SparrowPay's boot-time encrypted-configuration failures. Its dummy
application now uses `config/credentials/development.yml.enc` and the matching
Development key as the Rails runtime credentials, exactly matching the selected
Development console store. The Pay `ConsoleCredentials` fixture writes and
reads that one target only and resets only the dummy Rails credentials cache;
it does not add a console fallback or change Pay's production runtime.

Verification passed:

- `cd gems/sparrow_pay && bundle exec rspec` — 50 examples, 0 failures.
- `cd gems/sparrow_pay && bundle exec standardrb` — passed.
- `git diff --check` — passed.

Generated Pay dummy credential files were moved out of the worktree after the
run; no key or ciphertext fixture is retained for commit.

<!-- HANDOFF TO ui-engineer:
     Backend/test integration complete: SparrowPay's dummy runtime and credential fixture use the explicit Development target only.
     Controllers/routes: no changes.
     UI considerations: no UI contract changed; retain credential_target on console navigation and forms.
     Verification: full SparrowPay suite (50 examples), standardrb, and git diff --check pass.
     Next: ui-engineer may continue final UI integration checks; no UI-owned file was changed for this follow-up. -->

## Dummy Credential Fixture Hygiene — software-engineer

The four dummy test applications now remove their generated Development
ciphertext and key in an RSpec suite teardown. Cleanup is deliberately scoped
to `config/credentials/development.yml.enc` and `development.key`; it does not
touch Production files, generic credentials, or any non-test application
configuration. Each suite continues to create its explicit Development target
when needed, but normal test runs no longer leave encrypted credential/key
artifacts untracked in the worktree.

Verification passed:

- `bundle exec rake` — passed: SparrowMail, SparrowAuth (538 examples),
  SparrowPay (50 examples), SparrowUI (139 examples), documentation (25
  examples), StandardRB, and vocabulary checks all completed successfully.
- `find gems -path '*/spec/dummy/config/credentials/*' -type f -print` — no
  generated dummy credential or key files remained after the gate.
- `git diff --check` — passed.
- `git status --short` — contains only intentional source/track changes; no
  dummy `config/credentials` artifacts are present.

<!-- HANDOFF TO ui-engineer:
     Backend/test hygiene complete: all dummy credential runtimes still use the explicit Development target, with exact post-suite cleanup of their generated Development ciphertext/key files.
     Controllers/routes: no changes.
     UI considerations: no UI contract changed; retain credential_target on console navigation and forms.
     Verification: complete root bundle exec rake gate passes, and no dummy credential/key files remain in git status after it.
     Next: ui-engineer may perform final UI integration checks; no UI-owned file was changed for this hygiene follow-up. -->
