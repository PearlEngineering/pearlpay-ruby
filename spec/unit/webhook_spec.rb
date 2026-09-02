# frozen_string_literal: true

require "spec_helper"

RSpec.describe PearlPay::Webhook do
  # Shared vector with the PearlPay API's own test suite — do not change.
  let(:secret) { "whsec_test_secret_0123456789abcdef" }
  let(:timestamp) { 1_713_083_700 }
  let(:payload) do
    '{"id":"evt_4f9b9c1d2a52a113b8d0aa01","object":"event","type":"payment.succeeded",' \
      '"data":{"object":{"id":"pay_01JRXYZ1234ABCDEF","status":"succeeded"}}}'
  end
  let(:signature) { "v1=4ea1fbf7078c9d1d7bf35b52861def5747f21c3ce8ea95ed55bf89ba66ea38e1" }

  def verify!(**overrides)
    args = { payload: payload, timestamp: timestamp.to_s, signature: signature,
             secret: secret, tolerance: 300 }.merge(overrides)
    described_class.verify!(**args)
  end

  def expect_failure(reason, **overrides)
    expect { verify!(**overrides) }.to raise_error(PearlPay::WebhookSignatureError) { |e|
      expect(e.reason).to eq(reason)
    }
  end

  before do
    allow(Time).to receive(:now).and_return(Time.at(timestamp))
  end

  it "verifies the known vector and returns the event as a PearlPay::Object" do
    event = verify!
    expect(event).to be_a(PearlPay::Object)
    expect(event.type).to eq("payment.succeeded")
    expect(event.id).to eq("evt_4f9b9c1d2a52a113b8d0aa01")
    expect(event.data.object.id).to eq("pay_01JRXYZ1234ABCDEF")
  end

  it "signs the raw body itself, NOT its digest (unlike request signing)" do
    request_style = "v1=#{OpenSSL::HMAC.hexdigest(
      'SHA256', secret, "#{timestamp}.#{Digest::SHA256.hexdigest(payload)}"
    )}"
    expect_failure(:invalid, signature: request_style)
  end

  it "rejects a wrong secret as :invalid" do
    expect_failure(:invalid, secret: "whsec_wrong_secret")
  end

  it "rejects a re-serialized payload as :invalid (bytes must be exact)" do
    expect_failure(:invalid, payload: JSON.generate(JSON.parse(payload).merge("x" => 1)))
  end

  it "rejects an expired timestamp as :stale_timestamp" do
    old = timestamp - 301
    old_sig = "v1=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "#{old}.#{payload}")}"
    expect_failure(:stale_timestamp, timestamp: old.to_s, signature: old_sig)
  end

  it "rejects a future timestamp beyond tolerance as :stale_timestamp" do
    future = timestamp + 301
    future_sig = "v1=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "#{future}.#{payload}")}"
    expect_failure(:stale_timestamp, timestamp: future.to_s, signature: future_sig)
  end

  it "accepts a timestamp exactly at the tolerance boundary" do
    edge = timestamp - 300
    edge_sig = "v1=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "#{edge}.#{payload}")}"
    expect(verify!(timestamp: edge.to_s, signature: edge_sig)).to be_a(PearlPay::Object)
  end

  it "rejects a malformed scheme prefix as :malformed" do
    expect_failure(:malformed, signature: signature.sub("v1=", "v2="))
    expect_failure(:malformed, signature: signature.delete_prefix("v1="))
  end

  it "rejects a wrong-length signature as :malformed" do
    expect_failure(:malformed, signature: "v1=#{'a' * 63}")
    expect_failure(:malformed, signature: "v1=#{'a' * 65}")
    expect_failure(:malformed, signature: "v1=")
  end

  it "rejects non-hex signature bytes as :malformed" do
    expect_failure(:malformed, signature: "v1=#{'z' * 64}")
  end

  it "rejects missing or non-numeric timestamps as :malformed" do
    expect_failure(:malformed, timestamp: nil)
    expect_failure(:malformed, timestamp: "not-a-number")
    expect_failure(:malformed, timestamp: "17130.83700")
  end

  it "rejects a missing signature as :malformed" do
    expect_failure(:malformed, signature: nil)
  end

  it "uses constant-time comparison (OpenSSL.fixed_length_secure_compare)" do
    expect(OpenSSL).to receive(:fixed_length_secure_compare).and_call_original
    verify!
  end

  it "never compares unequal-length strings with the constant-time primitive" do
    # The bytesize pre-check guards fixed_length_secure_compare, which raises
    # on unequal lengths; malformed-length input must fail before comparison.
    expect(OpenSSL).not_to receive(:fixed_length_secure_compare)
    expect_failure(:malformed, signature: "v1=#{'a' * 10}")
  end

  it "raises :malformed when the verified payload is not valid JSON" do
    bad = "not json"
    sig = "v1=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "#{timestamp}.#{bad}")}"
    expect_failure(:malformed, payload: bad, signature: sig)
  end
end
