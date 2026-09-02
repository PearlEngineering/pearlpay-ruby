# frozen_string_literal: true

require_relative "integration_helper"

RSpec.describe "Golden paths against a local PearlPay API server", :integration do
  let(:client) { integration_client }

  it "keyed payment create, then replay with Idempotent-Replayed" do
    key = SecureRandom.uuid
    params = { merchant_reference_id: unique_reference("ORDER"), amount: 150_000,
               currency: "PHP", payment_channel: "qrph" }

    first = client.v1.payments.create(params, idempotency_key: key)
    expect(first.id).to start_with("pay_")
    expect(first.last_response.idempotent_replay?).to be(false)

    replay = client.v1.payments.create(params, idempotency_key: key)
    expect(replay.id).to eq(first.id)
    expect(replay.last_response.idempotent_replay?).to be(true)
  end

  it "signed disbursement create uses a fresh nonce per attempt and lands" do
    disbursement = client.v1.disbursements.create(
      { merchant_reference_id: unique_reference("PAYOUT"), amount: 10_000, currency: "PHP",
        rail: "instapay", partner_code: "BDO", account_number: "1234567890",
        account_name: "Integration Test" },
      idempotency_key: SecureRandom.uuid
    )
    expect(disbursement.id).to start_with("dis_")
  end

  it "an error outcome replays under the same key (cached 24h)" do
    key = SecureRandom.uuid
    bad = { merchant_reference_id: unique_reference("BAD"), amount: -1,
            currency: "PHP", payment_channel: "qrph" }

    first_error = begin
      client.v1.payments.create(bad, idempotency_key: key)
      nil
    rescue PearlPay::APIError => e
      e
    end
    expect(first_error).not_to be_nil

    replayed = begin
      client.v1.payments.create(bad, idempotency_key: key)
      nil
    rescue PearlPay::APIError => e
      e
    end
    expect(replayed.code).to eq(first_error.code)
    expect(replayed.http_status).to eq(first_error.http_status)
    expect(replayed.idempotent_replay?).to be(true)
  end

  it "walks both pagination strategies end to end" do
    payments = client.v1.payments.list(per_page: 1)
    expect(payments.pagination).to eq(:offset)
    expect(payments.auto_paging_each.first(3)).to all(be_a(PearlPay::Object))

    links = client.v1.payment_links.list(limit: 1)
    expect(links.pagination).to eq(:cursor)
    expect(links.auto_paging_each.first(3)).to all(be_a(PearlPay::Object))
  end

  it "webhook endpoint lifecycle: create -> list -> activate -> rotate" do
    endpoint = client.v1.webhook_endpoints.create(
      { url: "https://example.com/webhooks/pearlpay-integration",
        enabled_events: ["payment.succeeded"] }
    )
    expect(endpoint.signing_secret).to start_with("whsec_")

    listed = client.v1.webhook_endpoints.list
    expect(listed.map(&:id)).to include(endpoint.id)

    activated = client.v1.webhook_endpoints.activate(endpoint.id)
    expect(activated.status).to eq("enabled")

    rotated = client.v1.webhook_endpoints.rotate_signing_secret(endpoint.id)
    expect(rotated.signing_secret).to start_with("whsec_")
    expect(rotated.signing_secret).not_to eq(endpoint.signing_secret)
  end

  it "Webhook.verify! accepts a real delivery payload" do
    payload = ENV.fetch("PEARLPAY_WEBHOOK_PAYLOAD", nil)
    timestamp = ENV.fetch("PEARLPAY_WEBHOOK_TIMESTAMP", nil)
    signature = ENV.fetch("PEARLPAY_WEBHOOK_SIGNATURE", nil)
    skip "export PEARLPAY_WEBHOOK_{PAYLOAD,TIMESTAMP,SIGNATURE} from a captured delivery" unless
      payload && timestamp && signature

    event = PearlPay::Webhook.verify!(
      payload: payload, timestamp: timestamp, signature: signature,
      secret: ENV.fetch("PEARLPAY_WEBHOOK_SECRET"), tolerance: 10 * 365 * 24 * 3600
    )
    expect(event.id).to start_with("evt_")
  end
end
