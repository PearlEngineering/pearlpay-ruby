# pearlpay-ruby

Official Ruby SDK for [PearlPay](https://pearlpay.com)'s canonical `/v1` merchant API:
payments, disbursements, payment links, wallets, and webhooks.

- **Zero runtime dependencies** — stdlib only (`net/http`, `json`, `openssl`).
- **Immutable, thread-safe client** — construct one `PearlPay::Client` and share it
  across Puma/Sidekiq/Lambda threads. There is no global configuration.
- **Money is never a Float** — amounts are integer minor units (centavos) in and out;
  Floats are rejected before any network call. Wallet balances arrive as decimal
  strings and are passed through unchanged.
- Ruby >= 3.2.

## Installation

Not yet published to RubyGems — install straight from this repo:

```ruby
gem "pearlpay", git: "https://github.com/PearlEngineering/pearlpay-ruby.git", branch: "main"
```

To pin a specific commit instead of tracking `main`:

```ruby
gem "pearlpay", git: "https://github.com/PearlEngineering/pearlpay-ruby.git", ref: "<commit-sha>"
```

Then:

```bash
bundle install
```

Once published, this collapses to:

```ruby
gem "pearlpay"
```

## Quickstart: accept a payment

```ruby
require "pearlpay"

client = PearlPay::Client.new(
  api_key: ENV.fetch("PEARLPAY_API_KEY")          # sk_live_… / sk_test_…
)

payment = client.v1.payments.create(
  {
    merchant_reference_id: "ORDER-2026-00125",
    amount: 200_000,                               # ₱2,000.00 in centavos — always integers
    currency: "PHP",
    payment_channel: "qrph",
    redirect_url: "https://merchant.ph/checkout/return"
  },
  idempotency_key: "order-2026-00125"    # required — you own key generation
)

payment.id            # => "pay_01JRX…"
payment.status        # => "pending"
payment.checkout_url  # => "https://pay.pearlpay.ph/pay/chk_…" (may be null; see notes)
payment.last_response.idempotent_replay?  # true when the server replayed a cached outcome
```

## Quickstart: verify a webhook

Verify **the exact raw request body** — never re-parsed or re-serialized JSON:

```ruby
post "/webhooks/pearlpay" do
  event = PearlPay::Webhook.verify!(
    payload:   request.body.read,
    timestamp: request.env["HTTP_X_WEBHOOK_TIMESTAMP"],
    signature: request.env["HTTP_X_WEBHOOK_SIGNATURE"],
    secret:    ENV.fetch("PEARLPAY_WEBHOOK_SECRET")   # whsec_…, shown once at endpoint creation
  )

  case event.type
  when "payment.succeeded" then fulfill(event.data.object.id)
  end
  status 200
rescue PearlPay::WebhookSignatureError => e
  # e.reason => :invalid | :stale_timestamp | :malformed
  status 400
end
```

## Disbursements (request signing required)

`disbursements.create` requires HMAC request signing. Construct the client with your
`whsig_…` signing secret (rotate it via `client.v1.api_keys.rotate_signing_secret`):

```ruby
client = PearlPay::Client.new(
  api_key:        ENV.fetch("PEARLPAY_API_KEY"),
  signing_secret: ENV.fetch("PEARLPAY_SIGNING_SECRET")
)

disbursement = client.v1.disbursements.create(
  {
    merchant_reference_id: "PAYOUT-2026-00456",
    amount: 500_000, currency: "PHP",
    rail: "instapay", partner_code: "BDO",
    account_number: "1234567890", account_name: "Jose Reyes"
  },
  idempotency_key: "payout-2026-00456-attempt-1"
)
```

When a signing secret is configured, `payments.create` is signed too. Signing headers
(`X-Request-Timestamp`, `X-Request-Nonce`, `X-Signature`) are regenerated freshly on
every retry attempt; the serialized body bytes never change within a logical call.

## The surface

```ruby
client.v1.payments.create(params, idempotency_key:)  .retrieve(id)  .list(**filters)
client.v1.disbursements.create(params, idempotency_key:)  .retrieve(id)  .list(**filters)
client.v1.disbursement_rails.list  .partners(code)
client.v1.partners.list(channel:)
client.v1.wallets.balance                    # decimal strings, passed through untouched
client.v1.payment_links.create(params)       # idempotency key auto-generated if omitted
client.v1.payment_links.list(**filters)  .retrieve(id)  .update(id, params)
client.v1.payment_links.disable(id)  .clone(id, params)
client.v1.payment_links.checkout_url(id, params, idempotency_key:)
client.v1.webhook_endpoints.create(params)   # response includes whsec_… exactly once
client.v1.webhook_endpoints.list  .activate(id)  .rotate_signing_secret(id)
client.v1.api_keys.rotate_signing_secret(id)
client.raw_request(:get, "/payments/pay_123")  # escape hatch; path is relative to /v1
```

Every method accepts `opts:` with `idempotency_key:`, `headers:`, `open_timeout:`,
`read_timeout:`, and `max_network_retries:`.

## Pagination

```ruby
# Offset (payments, disbursements): page / per_page
client.v1.payments.list(status: "succeeded", per_page: 100).auto_paging_each do |payment|
  # every page is fetched through the full request pipeline
end

# Cursor (payment_links): limit / starting_after
page = client.v1.payment_links.list(limit: 25)
page.has_more?    # from meta
page.next_cursor  # meta.next_starting_after
```

## Idempotency and retries — read this before going live

- `payments.create`, `disbursements.create`, and `payment_links.checkout_url` **require**
  an `idempotency_key:` you generate and persist (per logical operation, ≤ 255 chars).
  Keys are scoped per merchant — never reuse one across endpoints. Keys expire after 24 h.
- The SDK automatically retries **transport failures, 429, and the one retryable
  `409 idempotency_in_progress`** (capped at 2 short waits) on those creates — same key,
  identical bytes, fresh signing headers. A **received** 5xx is **never** auto-retried:
  the server caches error outcomes under your key, and on `502 upstream_failure` the
  payment **was created** (marked `failed`, keeping its `merchant_reference_id`) — a
  fresh attempt needs a new key *and* a new reference.
- Reads and converge-to-state writes (`payment_links.update`/`disable`,
  `webhook_endpoints.activate`) retry transport failures, 429, and 5xx with
  exponential backoff and jitter (`Retry-After` is honored).
- `payment_links.clone`, `webhook_endpoints.create`, and both
  `rotate_signing_secret` operations are **never retried**: retries would mint
  duplicates or invalidate a secret you were just shown.

## Errors

```ruby
begin
  client.v1.payments.create(params, idempotency_key: key)
rescue PearlPay::RateLimitError => e
  sleep e.retry_after
rescue PearlPay::InvalidRequestError => e     # 400/410/422 — incl. business declines
  e.code          # "insufficient_balance", "fraud_declined", …
  e.request_id    # include in support requests
rescue PearlPay::ConflictError => e           # duplicate_reference / idempotency_*
rescue PearlPay::UpstreamError => e           # 502 — the payment exists and is failed
rescue PearlPay::ConnectionError => e         # transport failure, no HTTP response
end
```

Classification is by error `code` + HTTP status only — never message text. Every
`PearlPay::APIError` carries `code`, `http_status`, `request_id`, `details`, and
`last_response` (with `idempotent_replay?`, set on success **and** error replays).

## Instrumentation

Pass a callable; it receives one frozen Hash per HTTP attempt (allowlisted fields
only — never headers, bodies, or secrets). A raising hook never breaks a request.

```ruby
client = PearlPay::Client.new(
  api_key: key,
  instrumentation: ->(event) { StatsD.timing("pearlpay.#{event[:resource]}", event[:duration_ms]) }
)
```

Rails bridge (one line):

```ruby
instrumentation: ->(e) { ActiveSupport::Notifications.instrument("request.pearlpay", e) }
```

## Configuration reference

```ruby
PearlPay::Client.new(
  api_key:             "sk_live_…",              # required
  signing_secret:      "whsig_…",                # required for disbursements.create
  api_base:            "https://api.pearlpay.io", # origin only; the SDK owns /v1
  max_network_retries: 2,                        # transport-failure retries; 0 disables
  open_timeout:        5,                        # seconds
  read_timeout:        15,                       # 30 for payments.create / checkout_url
  instrumentation:     ->(event) { }             # optional
)
```

TLS verification is always on. Plain `http://` is allowed only for localhost.
Redirects are never followed. `inspect` output redacts all secrets.

## Multi-tenant apps

There's no global or module-level configuration, so nothing in the gem needs
changing to support multiple tenants — each `Client` is independently
constructed, frozen, and thread-safe, with its own `api_key` and
`signing_secret`. The work is entirely on the app side: build one `Client`
per tenant's credentials and cache it, rather than constructing one on every
request.

```ruby
class PearlPayClients
  def initialize
    @clients = Concurrent::Map.new
  end

  def for(tenant)
    @clients.compute_if_absent(tenant.id) do
      PearlPay::Client.new(
        api_key: tenant.pearlpay_api_key,
        signing_secret: tenant.pearlpay_signing_secret
      )
    end
  end

  # Call after rotating a tenant's key/secret so the next #for rebuilds it.
  def evict(tenant_id)
    @clients.delete(tenant_id)
  end
end

PEARLPAY_CLIENTS = PearlPayClients.new

# in a request/job, scoped to the current tenant:
PEARLPAY_CLIENTS.for(current_tenant).v1.payments.create(...)
```

`Concurrent::Map` (from the `concurrent-ruby` gem, a common Rails
dependency) keeps lookups thread-safe under Puma/Sidekiq without a mutex; a
plain `Hash` behind a `Mutex` works too. Whatever you use, evict a tenant's
entry when its credentials rotate — the map otherwise grows for the life of
the process, one entry per tenant that's made a request.

### Webhooks

`webhook_endpoints.create` (see [Quickstart: verify a
webhook](#quickstart-verify-a-webhook)) returns a distinct `signing_secret`
per endpoint you register — so give each tenant their own endpoint, on a URL
that identifies the tenant, and register it through that tenant's `Client`:

```ruby
endpoint = PEARLPAY_CLIENTS.for(tenant).v1.webhook_endpoints.create(
  url: "https://yourapp.com/webhooks/pearlpay/#{tenant.id}",
  enabled_events: ["*"]
)
tenant.update!(pearlpay_webhook_secret: endpoint.signing_secret) # whsec_…, shown once
```

The inbound route then reads the tenant straight out of the URL — no lookup
by API key or payload contents needed — and verifies against that tenant's
stored secret:

```ruby
post "/webhooks/pearlpay/:tenant_id" do
  tenant = Tenant.find(params[:tenant_id])

  event = PearlPay::Webhook.verify!(
    payload:   request.body.read,
    timestamp: request.env["HTTP_X_WEBHOOK_TIMESTAMP"],
    signature: request.env["HTTP_X_WEBHOOK_SIGNATURE"],
    secret:    tenant.pearlpay_webhook_secret
  )

  case event.type
  when "payment.succeeded" then fulfill(tenant, event.data.object.id)
  end
  status 200
rescue PearlPay::WebhookSignatureError => e
  status 400
end
```

Never resolve the tenant from the event payload before verifying — the
payload isn't trustworthy until `verify!` has checked it against a secret,
which means you need to know which secret *before* parsing anything.

## Development

```bash
bundle install
bundle exec rspec          # unit + contract (offline; WebMock)
bundle exec rubocop
```

The contract suite validates every request and response fixture against
`spec/contract/openapi.yaml`, vendored from the PearlPay API's OpenAPI
document. Refresh it with:

```bash
PEARLPAY_OPENAPI_SOURCE=/path/to/openapi.yaml bundle exec rake openapi:vendor
```

### Running the integration specs

`spec/integration` exercises the golden paths against a real server instead
of WebMock fixtures. It's opt-in — every example is skipped unless
`PEARLPAY_INTEGRATION=1` is set, and the rest of the suite keeps WebMock
active regardless. This is a PearlPay-maintainer workflow: it requires a
local instance of the PearlPay API itself, which is not part of this repo.

1. Start a local instance of the PearlPay API with a seeded merchant.
   `PEARLPAY_API_BASE` defaults to `http://localhost:3000`; never point it at
   a shared or production instance — a live key moves real money against
   whatever it points at.
2. Grab that merchant's **live** API key, request-signing secret, and webhook
   secret. Must be a live key (`sk_live_...`): the API rejects test-mode keys
   on the money-moving creates with `403 test_key_not_permitted`. See
   `spec/integration/integration_helper.rb` for exactly which golden-path
   examples that affects and why.
3. Run:

   ```bash
   PEARLPAY_INTEGRATION=1 PEARLPAY_API_BASE=http://localhost:3000 \
   PEARLPAY_API_KEY=sk_live_… PEARLPAY_SIGNING_SECRET=whsig_… \
   PEARLPAY_WEBHOOK_SECRET=whsec_… \
   bundle exec rspec spec/integration
   ```

The last example (`Webhook.verify!` against a captured delivery) stays
pending unless you also supply a real captured payload via env vars — see
`spec/integration/golden_paths_spec.rb` for which ones.

## License

MIT — see [LICENSE](LICENSE). Security reports: see [SECURITY.md](SECURITY.md).

The PearlPay Ruby SDK and the vendored OpenAPI specification are licensed
under the MIT License. PearlPay names, logos, and trademarks are not granted
under this license.
