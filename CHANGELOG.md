# Changelog

## 0.3.2 — 2026-09-02

Security fix and public-repo hardening ahead of open-sourcing.

- **Security fix**: `PearlPay::Object#inspect` no longer leaks
  `whsig_`/`whsec_` signing secrets from signing-secret-rotation and
  webhook-endpoint-creation responses — secret-shaped values are now
  redacted at any nesting depth. `#to_h`/`#to_hash` now return a
  deep-frozen copy instead of the internal data reference, so the
  read-only contract the class already documented is actually
  enforced.
- CI: added a gitleaks secret-scan job (full git history, every
  push/PR), a gem build/install/require smoke check, an
  `openapi-checksum` job that verifies the vendored contract against
  its stored checksum, Ruby 4.0 in the test matrix, and SHA-pinned
  GitHub Actions.
- Docs: removed internal service names, an internal filesystem path,
  and an internal backend class name from README, CHANGELOG,
  Rakefile, and spec comments/descriptions ahead of making this
  repository public.
- The vendored OpenAPI contract (`spec/contract/openapi.yaml`) is now
  licensed MIT, matching the SDK; see the License section in the
  README for the trademark carve-out.

## 0.3.1 — 2026-09-02

Docs only, no `lib/` changes.

- README: git-source install instructions (not yet published to RubyGems).
- README: step-by-step guide for running the integration specs, including
  the previously-missing `PEARLPAY_WEBHOOK_SECRET` env var.
- README: corrected which golden-path integration examples fail under a
  test-mode key (1, 2 and 3 — not 1 and 3), matching the API's actual
  behavior.
- README: multi-tenant usage — caching one `Client` per tenant, and
  registering/verifying a distinct webhook endpoint per tenant.

## 0.3.0 — 2026-08-30

Initial public surface: full coverage of the hardened `/v1` contract.

- `PearlPay::Client` — immutable, thread-safe, zero runtime dependencies.
- Payments, disbursements (signed), disbursement rails, partners, wallets,
  payment links, webhook endpoints, API key signing-secret rotation, and
  `raw_request`.
- Central request pipeline with per-operation retry classes
  (`:read` / `:idempotent_transport_only` / `:natural` / `:never`),
  exponential backoff with full jitter, and `Retry-After` support.
- Required caller-supplied idempotency keys for money movement;
  auto-generated keys for `payment_links.create` only.
- HMAC request signing (fresh nonce per attempt) and separate webhook
  delivery verification (`PearlPay::Webhook.verify!`, constant-time compare).
- Typed error hierarchy classified by error code + HTTP status.
- Offset and cursor pagination with `auto_paging_each`.
- Allowlisted per-attempt instrumentation events; secrets never leak into
  events, inspect output, or exception messages.
- Unit + contract suites; contract fixtures validated against the vendored
  `openapi.yaml`; opt-in integration suite (`PEARLPAY_INTEGRATION=1`).
