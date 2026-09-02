# frozen_string_literal: true

require_relative "contract_helper"

# Every service request (path/verb/params) and every response fixture is
# validated against the vendored openapi.yaml. Response fixtures come from
# the spec's own examples wherever it provides one.
RSpec.describe "Operation contracts" do
  path_ids = { "id" => "res_0123456789abcdef", "code" => "instapay" }.freeze

  payment_fixture = {
    "id" => "pay_01JRXYZ1234QRPHY", "object" => "payment",
    "merchant_reference_id" => "ORDER-2026-00125", "status" => "pending",
    "amount" => 200_000, "amount_decimal" => "2000.00", "currency" => "PHP",
    "checkout_url" => "https://pay.pearlpay.ph/pay/chk_01JRXYZ1234QRPHY",
    "created_at" => "2026-04-27T08:30:00Z"
  }.freeze

  disbursement_fixture = {
    "id" => "dis_01JRXYZ5678GHIJKL", "object" => "disbursement",
    "merchant_reference_id" => "PAYOUT-2026-00456", "status" => "queued",
    "amount" => 500_000, "amount_decimal" => "5000.00", "currency" => "PHP",
    "created_at" => "2026-04-14T08:30:00Z"
  }.freeze

  pagination_meta = {
    "page" => 1, "per_page" => 20, "total" => 1, "total_pages" => 1,
    "from" => "2026-01-14", "to" => "2026-04-14"
  }.freeze

  payment_link_fixture = {
    "id" => "plink_01JRXYZ1234ABCDEF", "object" => "payment_link", "status" => "active",
    "environment" => "live", "currency" => "PHP", "amount_type" => "fixed",
    "amount" => 150_000, "channel_mode" => "any", "channel" => nil,
    "url" => "https://pay.pearlpay.ph/pay/pl_01JRXYZ1234ABCDEF",
    "reusable" => true, "use_count" => 0, "max_uses" => nil,
    "title" => "Store checkout", "expires_at" => nil,
    "created_at" => "2026-04-14T08:00:00Z", "updated_at" => "2026-04-14T08:00:00Z"
  }.freeze

  webhook_endpoint_fixture = {
    "id" => "we_9f3c8a2b1d4e5f6a7b8c9d0e", "object" => "webhook_endpoint",
    "url" => "https://merchant.ph/webhooks/pearlpay", "status" => "enabled",
    "enabled_events" => ["payment.succeeded"], "description" => "Production",
    "signing_secret" => nil, "created_at" => "2026-04-14T08:00:00Z"
  }.freeze

  # op key => how to invoke it, the primary success status, and a response
  # fixture used when the spec has no example of its own. request params
  # default to the spec's own requestBody example.
  cases = {
    "payments.create" => {
      status: 201,
      invoke: ->(client, params) { client.v1.payments.create(params, idempotency_key: "ck-1") }
    },
    "payments.retrieve" => {
      status: 200, fixture: payment_fixture,
      invoke: ->(client, _params) { client.v1.payments.retrieve(path_ids["id"]) }
    },
    "payments.list" => {
      status: 200,
      fixture: { "object" => "list", "data" => [payment_fixture], "meta" => pagination_meta },
      invoke: ->(client, _params) { client.v1.payments.list(status: "succeeded", page: 1) }
    },
    "disbursements.create" => {
      status: 201,
      invoke: ->(client, params) { client.v1.disbursements.create(params, idempotency_key: "ck-2") }
    },
    "disbursements.retrieve" => {
      status: 200, fixture: disbursement_fixture,
      invoke: ->(client, _params) { client.v1.disbursements.retrieve(path_ids["id"]) }
    },
    "disbursements.list" => {
      status: 200,
      fixture: { "object" => "list", "data" => [disbursement_fixture], "meta" => pagination_meta },
      invoke: ->(client, _params) { client.v1.disbursements.list(status: "paid") }
    },
    "disbursement_rails.list" => {
      status: 200,
      invoke: ->(client, _params) { client.v1.disbursement_rails.list }
    },
    "disbursement_rails.partners" => {
      status: 200,
      invoke: ->(client, _params) { client.v1.disbursement_rails.partners(path_ids["code"]) }
    },
    "partners.list" => {
      status: 200,
      invoke: ->(client, _params) { client.v1.partners.list(channel: "instapay") }
    },
    "wallets.balance" => {
      status: 200,
      invoke: ->(client, _params) { client.v1.wallets.balance }
    },
    "payment_links.create" => {
      status: 201, params: { "title" => "Store checkout", "amount" => 150_000 },
      fixture: payment_link_fixture,
      invoke: ->(client, params) { client.v1.payment_links.create(params) }
    },
    "payment_links.list" => {
      status: 200,
      fixture: { "object" => "list", "data" => [payment_link_fixture],
                 "meta" => { "limit" => 25, "has_more" => false } },
      invoke: ->(client, _params) { client.v1.payment_links.list(status: "active", limit: 25) }
    },
    "payment_links.retrieve" => {
      status: 200, fixture: payment_link_fixture,
      invoke: ->(client, _params) { client.v1.payment_links.retrieve(path_ids["id"]) }
    },
    "payment_links.update" => {
      status: 200, params: { "title" => "New title" }, fixture: payment_link_fixture,
      invoke: ->(client, params) { client.v1.payment_links.update(path_ids["id"], params) }
    },
    "payment_links.disable" => {
      status: 200, fixture: payment_link_fixture.merge("status" => "disabled"),
      invoke: ->(client, _params) { client.v1.payment_links.disable(path_ids["id"]) }
    },
    "payment_links.clone" => {
      status: 201, params: { "title" => "Cloned" }, fixture: payment_link_fixture,
      invoke: ->(client, params) { client.v1.payment_links.clone(path_ids["id"], params) }
    },
    "payment_links.checkout_url" => {
      status: 201,
      params: { "merchant_reference_id" => "ORDER-2026-00200", "amount" => 150_000,
                "channel" => "qrph" },
      fixture: { "object" => "checkout_session",
                 "checkout_url" => "https://pay.pearlpay.ph/checkout/tok_abc",
                 "payment_id" => "pay_01JRXYZ1234ABCDEF", "expires_at" => nil },
      invoke: lambda { |client, params|
        client.v1.payment_links.checkout_url(path_ids["id"], params, idempotency_key: "ck-3")
      }
    },
    "webhook_endpoints.create" => {
      status: 201,
      invoke: ->(client, params) { client.v1.webhook_endpoints.create(params) }
    },
    "webhook_endpoints.list" => {
      status: 200, fixture: { "object" => "list", "data" => [webhook_endpoint_fixture] },
      invoke: ->(client, _params) { client.v1.webhook_endpoints.list }
    },
    "webhook_endpoints.activate" => {
      status: 200,
      invoke: ->(client, _params) { client.v1.webhook_endpoints.activate(path_ids["id"]) }
    },
    "webhook_endpoints.rotate_signing_secret" => {
      status: 200,
      fixture: { "object" => "webhook_signing_secret",
                 "webhook_endpoint_id" => "we_9f3c8a2b1d4e5f6a7b8c9d0e",
                 "signing_secret" => "whsec_test_fixture_not_a_real_secret",
                 "message" => "Store this secret securely; it is shown once." },
      invoke: ->(client, _params) { client.v1.webhook_endpoints.rotate_signing_secret(path_ids["id"]) }
    },
    "api_keys.rotate_signing_secret" => {
      status: 200,
      fixture: { "object" => "signing_secret",
                 "api_key_id" => "ak_live_9f3c8a2b1d4e5f6a7b8c9d0e",
                 "signing_secret" => "whsig_test_fixture_not_a_real_secret",
                 "message" => "Store this secret securely; it is shown once." },
      invoke: ->(client, _params) { client.v1.api_keys.rotate_signing_secret(path_ids["id"]) }
    }
  }.freeze

  it "covers every declared operation with a contract case" do
    expect(cases.keys).to match_array(PearlPay::V1Services.operations.keys)
  end

  cases.each do |op_name, spec_case|
    describe op_name do
      let(:meta) { PearlPay::V1Services.operations.fetch(op_name) }
      let(:verb) { meta[:method] }
      let(:template) { meta[:path] }
      let(:concrete_path) { template.gsub(/\{(\w+)\}/) { path_ids.fetch(Regexp.last_match(1)) } }
      let(:status) { spec_case[:status] }
      let(:params) do
        spec_case[:params] || ContractSupport.request_example(verb, template)
      end
      let(:fixture) do
        ContractSupport.response_example(verb, template, status) || spec_case[:fixture] ||
          raise("no response fixture for #{op_name}")
      end
      let(:client) do
        build_client(signing_secret: SpecSupport::SIGNING_SECRET, max_network_retries: 0)
      end

      it "sends the spec's verb+path and a schema-valid request, and its fixture " \
         "validates against the response schema" do
        captured = nil
        stub_request(verb.downcase.to_sym, /#{Regexp.escape("#{SpecSupport::BASE}/v1#{concrete_path}")}(\?.*)?\z/)
          .with do |req|
          captured = req
          true
        end
          .to_return(status: status, body: JSON.generate(fixture),
                     headers: { "Content-Type" => "application/json" })

        result = spec_case[:invoke].call(client, params)

        expect(captured).not_to be_nil, "no request captured for #{op_name}"
        expect(URI.parse(captured.uri.to_s).path).to eq("/v1#{concrete_path}")

        if captured.body && !captured.body.empty? && ContractSupport.has_request_body?(verb, template)
          schema = ContractSupport.request_schema(verb, template)
          ContractSupport.validate!(schema, JSON.parse(captured.body), "#{op_name} request body")
        end

        response_schema = ContractSupport.response_schema(verb, template, status)
        ContractSupport.validate!(response_schema, fixture, "#{op_name} #{status} fixture")

        expect(result).to be_a(PearlPay::Object).or be_a(PearlPay::ListObject)
        expect(result.last_response.http_status).to eq(status)
      end
    end
  end
end
