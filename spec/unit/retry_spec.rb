# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Retry behaviour by retry_class" do
  let(:payment_body) { JSON.generate(id: "pay_1", object: "payment", status: "pending") }
  let(:link_body) { JSON.generate(id: "plink_1", object: "payment_link") }

  describe ":read (every GET)" do
    it "retries transport failures up to max_network_retries with backoff" do
      stub_request(:get, "#{SpecSupport::BASE}/v1/payments/pay_1")
        .to_timeout.then.to_timeout.then
        .to_return(status: 200, body: payment_body, headers: json_headers)

      payment = build_client.v1.payments.retrieve("pay_1")
      expect(payment.id).to eq("pay_1")
      expect(recorded_sleeps.size).to eq(2)
      expect(recorded_sleeps).to all(be_between(0, 8.0))
    end

    it "gives up after max retries and raises TimeoutError" do
      stub_request(:get, "#{SpecSupport::BASE}/v1/payments/pay_1").to_timeout
      expect { build_client.v1.payments.retrieve("pay_1") }
        .to raise_error(PearlPay::TimeoutError)
      expect(WebMock).to have_requested(:get, "#{SpecSupport::BASE}/v1/payments/pay_1").times(3)
    end

    it "raises ConnectionError (not TimeoutError) for connection resets" do
      stub_request(:get, "#{SpecSupport::BASE}/v1/payments/pay_1")
        .to_raise(Errno::ECONNRESET)
      expect { build_client.v1.payments.retrieve("pay_1") }
        .to raise_error(PearlPay::ConnectionError) { |e|
          expect(e).not_to be_a(PearlPay::TimeoutError)
        }
    end

    it "retries received 5xx up to max" do
      stub_request(:get, "#{SpecSupport::BASE}/v1/payments/pay_1")
        .to_return(status: 500, body: error_body("internal_error"), headers: json_headers).then
        .to_return(status: 200, body: payment_body, headers: json_headers)
      expect(build_client.v1.payments.retrieve("pay_1").id).to eq("pay_1")
    end

    it "retries 429 honoring Retry-After" do
      stub_request(:get, "#{SpecSupport::BASE}/v1/payments/pay_1")
        .to_return(status: 429, body: error_body("rate_limit_exceeded"),
                   headers: json_headers("Retry-After" => "60")).then
        .to_return(status: 200, body: payment_body, headers: json_headers)
      expect(build_client.v1.payments.retrieve("pay_1").id).to eq("pay_1")
      expect(recorded_sleeps).to eq([60.0])
    end

    it "raises other received 4xx without retrying" do
      stub_request(:get, "#{SpecSupport::BASE}/v1/payments/pay_1")
        .to_return(status: 404, body: error_body("not_found"), headers: json_headers)
      expect { build_client.v1.payments.retrieve("pay_1") }
        .to raise_error(PearlPay::NotFoundError)
      expect(WebMock).to have_requested(:get, "#{SpecSupport::BASE}/v1/payments/pay_1").once
    end
  end

  describe ":idempotent_transport_only (keyed creates)" do
    it "retries transport failures with the same key and identical frozen bytes but fresh signing headers" do
      requests = []
      capture = ->(req) { requests << req; true } # rubocop:disable Style/Semicolon
      stub_request(:post, "#{SpecSupport::BASE}/v1/disbursements")
        .with(&capture)
        .to_timeout.then.to_timeout.then
        .to_return(status: 201, body: JSON.generate(id: "dis_1"), headers: json_headers)

      client = build_client(signing_secret: SpecSupport::SIGNING_SECRET)
      client.v1.disbursements.create({ amount: 1000, account_number: "123" }, idempotency_key: "key-9")

      expect(requests.size).to eq(3)
      expect(requests.map(&:body).uniq.size).to eq(1)
      expect(requests.map { |r| r.headers["Idempotency-Key"] }.uniq).to eq(["key-9"])
      nonces = requests.map { |r| r.headers["X-Request-Nonce"] }
      expect(nonces.uniq.size).to eq(3)
      signatures = requests.map { |r| r.headers["X-Signature"] }
      expect(signatures.uniq.size).to eq(3)
      request_ids = requests.map { |r| r.headers["X-Request-Id"] }
      expect(request_ids.uniq.size).to eq(3)
    end

    it "keeps the auto-generated payment_links.create key stable across internal retries" do
      keys = []
      stub_request(:post, "#{SpecSupport::BASE}/v1/payment_links")
        .with do |req|
        keys << req.headers["Idempotency-Key"]
        true
      end
        .to_timeout.then
                   .to_return(status: 201, body: link_body, headers: json_headers)
      build_client.v1.payment_links.create({ title: "T" })
      expect(keys.size).to eq(2)
      expect(keys.uniq.size).to eq(1)
    end

    it "NEVER auto-retries a received 5xx on a keyed create" do
      stub_request(:post, "#{SpecSupport::BASE}/v1/payments")
        .to_return(status: 500, body: error_body("internal_error"), headers: json_headers)
      expect { build_client.v1.payments.create({ amount: 1 }, idempotency_key: "k") }
        .to raise_error(PearlPay::APIError)
      expect(WebMock).to have_requested(:post, "#{SpecSupport::BASE}/v1/payments").once
    end

    it "never auto-retries a 502 upstream_failure (the payment was created and failed)" do
      stub_request(:post, "#{SpecSupport::BASE}/v1/payments")
        .to_return(status: 502, body: error_body("upstream_failure"), headers: json_headers)
      expect { build_client.v1.payments.create({ amount: 1 }, idempotency_key: "k") }
        .to raise_error(PearlPay::UpstreamError)
      expect(WebMock).to have_requested(:post, "#{SpecSupport::BASE}/v1/payments").once
    end

    it "retries 429 without consuming the key" do
      stub_request(:post, "#{SpecSupport::BASE}/v1/payments")
        .to_return(status: 429, body: error_body("rate_limit_exceeded"),
                   headers: json_headers("Retry-After" => "60")).then
        .to_return(status: 201, body: payment_body, headers: json_headers)
      payment = build_client.v1.payments.create({ amount: 1 }, idempotency_key: "k")
      expect(payment.id).to eq("pay_1")
      expect(recorded_sleeps).to eq([60.0])
    end

    it "retries 409 idempotency_in_progress at most twice with short waits, same key" do
      keys = []
      stub_request(:post, "#{SpecSupport::BASE}/v1/payments")
        .with do |req|
        keys << req.headers["Idempotency-Key"]
        true
      end
        .to_return(status: 409, body: error_body("idempotency_in_progress"), headers: json_headers)
      expect { build_client.v1.payments.create({ amount: 1 }, idempotency_key: "k") }
        .to raise_error(PearlPay::IdempotencyInProgressError)
      expect(keys.size).to eq(3) # initial + 2 retries
      expect(keys.uniq).to eq(["k"])
      expect(recorded_sleeps.size).to eq(2)
    end

    it "does not retry the terminal 409s" do
      %w[duplicate_reference idempotency_conflict].each do |code|
        WebMock.reset!
        stub_request(:post, "#{SpecSupport::BASE}/v1/payments")
          .to_return(status: 409, body: error_body(code), headers: json_headers)
        expect { build_client.v1.payments.create({ amount: 1 }, idempotency_key: "k") }
          .to raise_error(PearlPay::ConflictError)
        expect(WebMock).to have_requested(:post, "#{SpecSupport::BASE}/v1/payments").once
      end
    end
  end

  describe ":natural (converge-to-state writes)" do
    it "retries transport failures and received 5xx" do
      stub_request(:post, "#{SpecSupport::BASE}/v1/payment_links/plink_1/disable")
        .to_timeout.then
        .to_return(status: 500, body: error_body("internal_error"), headers: json_headers).then
        .to_return(status: 200, body: link_body, headers: json_headers)
      expect(build_client.v1.payment_links.disable("plink_1").id).to eq("plink_1")
    end
  end

  describe ":never (duplicate-minting and destructive operations)" do
    it "never retries transport failures on clone" do
      stub_request(:post, "#{SpecSupport::BASE}/v1/payment_links/plink_1/clone").to_timeout
      expect { build_client.v1.payment_links.clone("plink_1") }
        .to raise_error(PearlPay::TimeoutError)
      expect(WebMock).to have_requested(:post, "#{SpecSupport::BASE}/v1/payment_links/plink_1/clone").once
    end

    it "never retries webhook_endpoints.create, even on 429 or 5xx" do
      stub_request(:post, "#{SpecSupport::BASE}/v1/webhook_endpoints")
        .to_return(status: 429, body: error_body("rate_limit_exceeded"),
                   headers: json_headers("Retry-After" => "60"))
      expect { build_client.v1.webhook_endpoints.create({ url: "https://m.ph/wh" }) }
        .to raise_error(PearlPay::RateLimitError)
      expect(WebMock).to have_requested(:post, "#{SpecSupport::BASE}/v1/webhook_endpoints").once
      expect(recorded_sleeps).to be_empty
    end

    it "never retries rotations even with per-call max_network_retries raised" do
      stub_request(:post, "#{SpecSupport::BASE}/v1/api_keys/ak_live_1/rotate_signing_secret")
        .to_timeout
      expect do
        build_client.v1.api_keys.rotate_signing_secret("ak_live_1", opts: { max_network_retries: 5 })
      end.to raise_error(PearlPay::TimeoutError)
      expect(WebMock)
        .to have_requested(:post, "#{SpecSupport::BASE}/v1/api_keys/ak_live_1/rotate_signing_secret").once
    end
  end

  describe "per-call overrides" do
    it "max_network_retries: 0 disables transport retries on reads" do
      stub_request(:get, "#{SpecSupport::BASE}/v1/payments/pay_1").to_timeout
      expect do
        build_client.v1.payments.retrieve("pay_1", opts: { max_network_retries: 0 })
      end.to raise_error(PearlPay::TimeoutError)
      expect(WebMock).to have_requested(:get, "#{SpecSupport::BASE}/v1/payments/pay_1").once
    end

    it "a raised per-call max_network_retries extends read retries" do
      stub_request(:get, "#{SpecSupport::BASE}/v1/payments/pay_1")
        .to_timeout.then.to_timeout.then.to_timeout.then.to_timeout.then
        .to_return(status: 200, body: payment_body, headers: json_headers)
      payment = build_client.v1.payments.retrieve("pay_1", opts: { max_network_retries: 4 })
      expect(payment.id).to eq("pay_1")
    end
  end

  describe "backoff shape" do
    it "uses exponential caps with full jitter (base 0.5, cap 8)" do
      policy = PearlPay::RetryPolicy.new(max_retries: 10, rng: Random.new(42))
      caps = (0..10).map { |n| [8.0, 0.5 * (2**n)].min }
      expect(caps.first).to eq(0.5)
      expect(caps.last).to eq(8.0)
      100.times do
        (0..10).each do |n|
          expect(policy.delay(n)).to be_between(0, caps[n])
        end
      end
    end

    it "lets Retry-After win over computed backoff" do
      policy = PearlPay::RetryPolicy.new(max_retries: 2)
      expect(policy.delay(0, retry_after: "60")).to eq(60.0)
    end
  end
end
