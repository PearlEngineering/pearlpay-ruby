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

  describe "payments.cancel (:natural, no idempotency key)" do
    let(:url) { "#{SpecSupport::BASE}/v1/payments/pay_1/cancel" }

    it "sends no Idempotency-Key and retries a 503 status_check_unavailable" do
      stub_request(:post, url)
        .to_return(status: 503, body: error_body("status_check_unavailable"), headers: json_headers).then
        .to_return(status: 200, body: payment_body, headers: json_headers)
      expect(build_client.v1.payments.cancel("pay_1").id).to eq("pay_1")
      expect(WebMock).to have_requested(:post, url).twice
      expect(WebMock).not_to(have_requested(:post, url).with { |req| req.headers.key?("Idempotency-Key") })
    end

    it "raises APIError once retries are exhausted on 503" do
      stub_request(:post, url)
        .to_return(status: 503, body: error_body("status_check_unavailable"), headers: json_headers)
      expect { build_client.v1.payments.cancel("pay_1") }.to raise_error(PearlPay::APIError)
    end

    %w[payment_already_succeeded payment_in_progress payment_not_cancellable
       payment_under_review].each do |code|
      it "raises ConflictError without retrying on 409 #{code}" do
        stub_request(:post, url)
          .to_return(status: 409, body: error_body(code), headers: json_headers)
        expect { build_client.v1.payments.cancel("pay_1") }.to raise_error(PearlPay::ConflictError)
        expect(WebMock).to have_requested(:post, url).once
      end
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

  describe "Retry-After ceiling" do
    let(:cancel_url) { "#{SpecSupport::BASE}/v1/payments/pay_1/cancel" }
    let(:get_url) { "#{SpecSupport::BASE}/v1/payments/pay_1" }

    def rate_limited(retry_after, status: 429, code: "rate_limit_exceeded")
      { status: status, body: error_body(code), headers: json_headers("Retry-After" => retry_after) }
    end

    it "raises instead of sleeping on a cancel 503 with Retry-After 3600" do
      stub_request(:post, cancel_url)
        .to_return(rate_limited("3600", status: 503, code: "status_check_unavailable"))
      expect { build_client.v1.payments.cancel("pay_1") }.to raise_error(PearlPay::APIError) { |e|
        expect(e.code).to eq("status_check_unavailable")
        expect(e.retry_after).to eq(3600)
      }
      expect(WebMock).to have_requested(:post, cancel_url).once
      expect(recorded_sleeps).to be_empty
    end

    it "still retries a cancel 503 with the documented 5s Retry-After" do
      stub_request(:post, cancel_url)
        .to_return(rate_limited("5", status: 503, code: "status_check_unavailable")).then
        .to_return(status: 200, body: payment_body, headers: json_headers)
      build_client.v1.payments.cancel("pay_1")
      expect(recorded_sleeps).to eq([5.0])
    end

    it "raises RateLimitError above the cap, sleeps at the cap" do
      stub_request(:get, get_url).to_return(rate_limited("61"))
      expect { build_client.v1.payments.retrieve("pay_1") }.to raise_error(PearlPay::RateLimitError)
      expect(WebMock).to have_requested(:get, get_url).once
      expect(recorded_sleeps).to be_empty

      WebMock.reset!
      stub_request(:get, get_url).to_return(rate_limited("60")).then
                                 .to_return(status: 200, body: payment_body, headers: json_headers)
      build_client.v1.payments.retrieve("pay_1")
      expect(recorded_sleeps).to eq([60.0])
    end

    it "honours a lower client cap" do
      stub_request(:get, get_url).to_return(rate_limited("60"))
      expect { build_client(max_retry_after: 30).v1.payments.retrieve("pay_1") }
        .to raise_error(PearlPay::RateLimitError)
      expect(recorded_sleeps).to be_empty
    end

    it "lets a per-request value override the client value in both directions" do
      stub_request(:get, get_url).to_return(rate_limited("120")).then
                                 .to_return(status: 200, body: payment_body, headers: json_headers)
      build_client.v1.payments.retrieve("pay_1", opts: { max_retry_after: 300 })
      expect(recorded_sleeps).to eq([120.0])

      WebMock.reset!
      stub_request(:get, get_url).to_return(rate_limited("45"))
      client = build_client(max_retry_after: 300)
      expect { client.v1.payments.retrieve("pay_1", opts: { max_retry_after: 30 }) }
        .to raise_error(PearlPay::RateLimitError)
    end

    it "treats max_retry_after: 0 as raise-on-any-Retry-After" do
      stub_request(:get, get_url).to_return(rate_limited("1"))
      expect { build_client(max_retry_after: 0).v1.payments.retrieve("pay_1") }
        .to raise_error(PearlPay::RateLimitError)
      expect(recorded_sleeps).to be_empty
    end

    it "restores uncapped behaviour with Float::INFINITY" do
      stub_request(:get, get_url).to_return(rate_limited("3600")).then
                                 .to_return(status: 200, body: payment_body, headers: json_headers)
      build_client(max_retry_after: Float::INFINITY).v1.payments.retrieve("pay_1")
      expect(recorded_sleeps).to eq([3600.0])
    end

    ["abc", "Wed, 21 Oct 2026 07:28:00 GMT", "0", "60abc", "60.5"].each do |value|
      it "falls back to backoff for Retry-After #{value.inspect}" do
        stub_request(:get, get_url).to_return(rate_limited(value)).then
                                   .to_return(status: 200, body: payment_body, headers: json_headers)
        build_client.v1.payments.retrieve("pay_1")
        expect(recorded_sleeps.size).to eq(1)
        expect(recorded_sleeps.first).to be_between(0, 0.5)
      end
    end

    it "never retries a :never operation, whatever the Retry-After" do
      stub_request(:post, "#{SpecSupport::BASE}/v1/webhook_endpoints").to_return(rate_limited("3600"))
      expect { build_client.v1.webhook_endpoints.create({ url: "https://m.ph/wh" }) }
        .to raise_error(PearlPay::RateLimitError)
      expect(WebMock).to have_requested(:post, "#{SpecSupport::BASE}/v1/webhook_endpoints").once
      expect(recorded_sleeps).to be_empty
    end

    it "raises a keyed create's 429 above the cap without resending the key" do
      keys = []
      stub_request(:post, "#{SpecSupport::BASE}/v1/payments")
        .with { |req| keys << req.headers["Idempotency-Key"] }
        .to_return(rate_limited("120"))
      expect { build_client.v1.payments.create({ amount: 1 }, idempotency_key: "k") }
        .to raise_error(PearlPay::RateLimitError)
      expect(keys).to eq(["k"])
      expect(recorded_sleeps).to be_empty
    end

    it "applies to raw_request opts" do
      stub_request(:get, "#{SpecSupport::BASE}/v1/things").to_return(rate_limited("60"))
      expect { build_client.raw_request(:get, "/things", opts: { max_retry_after: 10 }) }
        .to raise_error(PearlPay::RateLimitError)
      expect(recorded_sleeps).to be_empty
    end

    it "rejects invalid per-request values before any request" do
      expect { build_client.v1.payments.retrieve("pay_1", opts: { max_retry_after: -1 }) }
        .to raise_error(ArgumentError, /max_retry_after/)
      expect(WebMock).not_to have_requested(:get, get_url)
    end

    describe PearlPay::RetryPolicy do
      it "parses Retry-After as positive delta-seconds only" do
        parse = described_class.method(:parse_retry_after)
        expect(parse.call("60")).to eq(60.0)
        expect(parse.call(" 5 ")).to eq(5.0)
        ["0", "-3", "abc", "Wed, 21 Oct 2026 07:28:00 GMT", "", nil].each do |v|
          expect(parse.call(v)).to be_nil
        end
      end

      it "downgrades :retry to :raise only above the cap" do
        policy = described_class.new(max_retries: 2, max_retry_after: 60)
        decide = lambda do |ra|
          policy.response_decision(:read, status: 429, code: "x", retries_so_far: 0,
                                          in_progress_retries: 0, retry_after: ra)
        end
        expect(decide.call(60.0)).to eq(:retry)
        expect(decide.call(60.1)).to eq(:raise)
        expect(decide.call(nil)).to eq(:retry)
      end
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
