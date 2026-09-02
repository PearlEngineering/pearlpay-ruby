# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Instrumentation" do
  let(:payment_body) { JSON.generate(id: "pay_1", object: "payment") }

  it "emits one frozen allowlist-built event per attempt" do
    events = []
    stub_request(:post, "#{SpecSupport::BASE}/v1/payments")
      .to_return(status: 201, body: payment_body, headers: json_headers)

    build_client(events: events).v1.payments.create({ amount: 1 }, idempotency_key: "k")

    expect(events.size).to eq(1)
    event = events.first
    expect(event).to be_frozen
    expect(event.keys).to match_array(PearlPay::Instrumentation::KEYS)
    expect(event).to include(
      sdk_version: PearlPay::VERSION, ruby_version: RUBY_VERSION,
      api_version: "2026-04-14", resource: "payments", operation: "create",
      method: "POST", path: "/v1/payments", status: 201, attempt: 1,
      retry_count: 0, idempotency_key_present: true, idempotent_replay: false,
      error_code: nil
    )
    expect(event[:duration_ms]).to be_a(Numeric)
    expect(event[:request_id]).to match(/\A\h{8}-/)
  end

  it "emits per attempt across retries, including transport failures" do
    events = []
    stub_request(:get, "#{SpecSupport::BASE}/v1/payments/pay_1")
      .to_timeout.then
      .to_return(status: 500, body: error_body("internal_error"), headers: json_headers).then
      .to_return(status: 200, body: payment_body, headers: json_headers)

    build_client(events: events).v1.payments.retrieve("pay_1", opts: { max_network_retries: 3 })

    expect(events.map { |e| e[:attempt] }).to eq([1, 2, 3])
    expect(events.map { |e| e[:status] }).to eq([nil, 500, 200])
    expect(events.map { |e| e[:error_code] }).to eq(["timeout", "internal_error", nil])
    expect(events.map { |e| e[:request_id] }.uniq.size).to eq(3)
  end

  it "reports idempotent replays" do
    events = []
    stub_request(:post, "#{SpecSupport::BASE}/v1/payments")
      .to_return(status: 201, body: payment_body,
                 headers: json_headers("Idempotent-Replayed" => "true"))
    build_client(events: events).v1.payments.create({ amount: 1 }, idempotency_key: "k")
    expect(events.first[:idempotent_replay]).to be(true)
  end

  it "a failing hook never breaks the request, and warns once" do
    warnings = []
    allow(Kernel).to receive(:warn) { |msg| warnings << msg }
    boom = ->(_event) { raise "hook exploded" }
    stub_request(:get, "#{SpecSupport::BASE}/v1/payments/pay_1")
      .to_return(status: 200, body: payment_body, headers: json_headers)

    client = build_client(instrumentation: boom)
    expect(client.v1.payments.retrieve("pay_1").id).to eq("pay_1")
    expect(client.v1.payments.retrieve("pay_1").id).to eq("pay_1")
    expect(warnings.grep(/instrumentation hook raised/).size).to eq(1)
  end
end
