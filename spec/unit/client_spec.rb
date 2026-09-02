# frozen_string_literal: true

require "spec_helper"

RSpec.describe PearlPay::Client do
  it "is immutable and exposes the frozen v1 surface" do
    client = build_client
    expect(client).to be_frozen
    expect(client.config).to be_frozen
    expect(client.v1).to be_frozen
    %i[payments disbursements disbursement_rails partners wallets
       payment_links webhook_endpoints api_keys].each do |service|
      expect(client.v1.public_send(service)).to be_frozen
    end
  end

  it "has no global default client and no mutable module config" do
    expect(PearlPay).not_to respond_to(:api_key=)
    expect(PearlPay).not_to respond_to(:client)
    expect(PearlPay).not_to respond_to(:configure)
  end

  it "redacts secrets in #inspect" do
    client = build_client(signing_secret: SpecSupport::SIGNING_SECRET)
    expect(client.inspect).to include("[REDACTED]")
    expect(client.inspect).not_to include(SpecSupport::API_KEY)
  end

  describe "#raw_request" do
    it "goes through the same pipeline, path relative to /v1" do
      stub_request(:get, "#{SpecSupport::BASE}/v1/payments/pay_1?expand=customer")
        .to_return(status: 200, body: JSON.generate(id: "pay_1", object: "payment"),
                   headers: json_headers)
      result = build_client.raw_request(:get, "/payments/pay_1", params: { expand: "customer" })
      expect(result.id).to eq("pay_1")
    end

    it "rejects paths that are not /v1-relative" do
      client = build_client
      expect { client.raw_request(:get, "v1/payments") }.to raise_error(ArgumentError, /starting with/)
      expect { client.raw_request(:get, "/v1/payments") }.to raise_error(ArgumentError, %r{relative to /v1})
    end

    it "defaults writes to :never — no retries" do
      stub_request(:post, "#{SpecSupport::BASE}/v1/payments/pay_1/void").to_timeout
      expect { build_client.raw_request(:post, "/payments/pay_1/void", params: { r: 1 }) }
        .to raise_error(PearlPay::TimeoutError)
      expect(WebMock).to have_requested(:post, "#{SpecSupport::BASE}/v1/payments/pay_1/void").once
    end

    it "defaults GETs to :read — transport retries apply" do
      stub_request(:get, "#{SpecSupport::BASE}/v1/wallets/balance")
        .to_timeout.then
        .to_return(status: 200, body: JSON.generate(updated_at: "now"), headers: json_headers)
      expect(build_client.raw_request(:get, "/wallets/balance").updated_at).to eq("now")
    end

    it "honors caller-declared retry_class, idempotency_key, and signing via opts" do
      captured = nil
      stub_request(:post, "#{SpecSupport::BASE}/v1/payments")
        .with do |req|
        captured = req.headers
        true
      end
        .to_timeout.then
                   .to_return(status: 201, body: JSON.generate(id: "pay_1"), headers: json_headers)

      client = build_client(signing_secret: SpecSupport::SIGNING_SECRET)
      client.raw_request(:post, "/payments", params: { amount: 1 },
                                             opts: { retry_class: :idempotent_transport_only,
                                                     idempotency_key: "raw-key", signing: :required })
      expect(captured["Idempotency-Key"]).to eq("raw-key")
      expect(captured).to have_key("X-Signature")
      expect(WebMock).to have_requested(:post, "#{SpecSupport::BASE}/v1/payments").twice
    end

    it "raising signing: :required without a secret fails locally" do
      expect do
        build_client.raw_request(:post, "/payments", params: {}, opts: { signing: :required })
      end.to raise_error(PearlPay::ConfigurationError)
    end

    it "rejects unknown retry_class and signing values" do
      client = build_client
      expect { client.raw_request(:get, "/x", opts: { retry_class: :always }) }
        .to raise_error(ArgumentError, /retry_class/)
      expect { client.raw_request(:get, "/x", opts: { signing: :sometimes }) }
        .to raise_error(ArgumentError, /signing/)
    end

    it "rejects floats in raw params too" do
      expect { build_client.raw_request(:post, "/payments", params: { amount: 1.5 }) }
        .to raise_error(ArgumentError, /centavos/)
    end
  end

  it "memoizes nothing — the v1 surface is identity-stable" do
    client = build_client
    expect(client.v1).to equal(client.v1)
    expect(client.v1.payments).to equal(client.v1.payments)
    expect(client.config).to equal(client.config)
  end
end
