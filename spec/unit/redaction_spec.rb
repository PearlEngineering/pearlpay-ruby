# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Secret redaction" do
  let(:forbidden_markers) { %w[sk_live_ sk_test_ whsig_ whsec_ Bearer] }
  let(:live_key) { "sk_live_#{'cd' * 24}" }

  def scan!(text, context)
    forbidden_markers.each do |marker|
      expect(text).not_to include(marker), "#{context} leaked #{marker.inspect}: #{text}"
    end
  end

  it "scans every emitted event and all inspect output across success, error, and transport paths" do
    events = []
    client = PearlPay::Client.new(
      api_key: live_key, signing_secret: SpecSupport::SIGNING_SECRET,
      instrumentation: ->(event) { events << event }
    )

    stub_request(:post, "#{SpecSupport::BASE}/v1/disbursements")
      .to_return(status: 201, body: JSON.generate(id: "dis_1"), headers: json_headers)
    stub_request(:post, "#{SpecSupport::BASE}/v1/payments")
      .to_return(status: 422, body: error_body("insufficient_balance"), headers: json_headers)
    stub_request(:get, "#{SpecSupport::BASE}/v1/payments/pay_1").to_timeout

    client.v1.disbursements.create({ amount: 1, account_number: "12345678" }, idempotency_key: "k")
    begin
      client.v1.payments.create({ amount: 1 }, idempotency_key: "k")
    rescue PearlPay::APIError => e
      scan!(e.message, "APIError message")
      scan!(e.inspect, "APIError inspect")
    end
    begin
      client.v1.payments.retrieve("pay_1")
    rescue PearlPay::ConnectionError => e
      scan!(e.message, "transport error message")
    end

    expect(events).not_to be_empty
    events.each do |event|
      scan!(event.inspect, "instrumentation event")
      # Allowlist: no header or body material at all.
      expect(event.keys).to match_array(PearlPay::Instrumentation::KEYS)
      expect(event.values.join(" ")).not_to include("account_number")
      expect(event.values.join(" ")).not_to include("12345678")
    end

    scan!(client.inspect, "Client#inspect")
    scan!(client.to_s, "Client#to_s")
    scan!(client.config.inspect, "Configuration#inspect")
  end

  it "ConfigurationError for a missing signing secret does not embed the api key" do
    client = PearlPay::Client.new(api_key: live_key)
    expect { client.v1.disbursements.create({ amount: 1 }, idempotency_key: "k") }
      .to raise_error(PearlPay::ConfigurationError) { |e|
        scan!(e.message, "ConfigurationError message")
      }
  end
end
