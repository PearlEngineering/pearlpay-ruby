# frozen_string_literal: true

require "spec_helper"

RSpec.describe PearlPay::RequestSignature do
  # Shared vector — the PearlPay API's own test suite asserts the same
  # fixture against its request-signature verification. Do not change these
  # values.
  let(:secret) { "whsig_test_secret_0123456789abcdef" }
  let(:timestamp) { 1_713_083_700 }
  let(:nonce) { "f3d1a7c9b5e2048612aa34cc56ee78ff" }
  let(:body) { '{"merchant_reference_id":"ORDER-2026-00125","amount":200000,"payment_channel":"qrph"}' }
  let(:expected_signature) { "v1=da64197a7defc41a6ca8c5a56fd0992c8416d29a931078b3e41f668bcffe1c9c" }

  it "signs HMAC-SHA256 over timestamp.nonce.SHA256(body) — the known vector" do
    signature = described_class.signature(secret: secret, body: body,
                                          timestamp: timestamp, nonce: nonce)
    expect(signature).to eq(expected_signature)
  end

  it "hashes the empty string for empty bodies — the known empty-body vector" do
    signature = described_class.signature(secret: secret, body: nil,
                                          timestamp: timestamp, nonce: nonce)
    expect(signature).to eq("v1=1532cd0c752d0ea1993802f58a2631239b6cfd06b5715a4e599dc29f1a7a8d07")
    expect(described_class.signature(secret: secret, body: "", timestamp: timestamp, nonce: nonce))
      .to eq(signature)
  end

  it "emits the three signing headers" do
    headers = described_class.headers(secret: secret, body: body,
                                      timestamp: timestamp, nonce: nonce)
    expect(headers).to eq(
      "X-Request-Timestamp" => "1713083700",
      "X-Request-Nonce" => nonce,
      "X-Signature" => expected_signature
    )
  end

  it "generates a fresh <=64-byte hex nonce and current timestamp by default" do
    headers = described_class.headers(secret: secret, body: body)
    expect(headers["X-Request-Nonce"]).to match(/\A\h{32}\z/)
    expect(headers["X-Request-Timestamp"].to_i).to be_within(5).of(Time.now.to_i)
  end
end
