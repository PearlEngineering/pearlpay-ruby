# frozen_string_literal: true

require "spec_helper"

RSpec.describe PearlPay::Requestor do
  let(:payment_body) { JSON.generate(id: "pay_1", object: "payment", status: "pending", amount: 1000) }

  describe "standard headers" do
    it "sends auth, accept, user-agent, api-version, and a per-attempt request id" do
      captured = nil
      stub_request(:get, "#{SpecSupport::BASE}/v1/payments/pay_1")
        .with do |req|
        captured = req.headers
        true
      end
        .to_return(status: 200, body: payment_body, headers: json_headers)

      build_client.v1.payments.retrieve("pay_1")

      expect(captured["Authorization"]).to eq("Bearer #{SpecSupport::API_KEY}")
      expect(captured["Accept"]).to eq("application/json")
      expect(captured["User-Agent"]).to eq("pearlpay-ruby/#{PearlPay::VERSION} ruby/#{RUBY_VERSION}")
      expect(captured["X-Api-Version"]).to eq("2026-04-14")
      expect(captured["X-Request-Id"]).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
      expect(captured).not_to have_key("Content-Type")
      expect(captured).not_to have_key("Idempotency-Key")
      expect(captured).not_to have_key("X-Signature")
    end

    it "sends Content-Type and Idempotency-Key on keyed creates" do
      captured = nil
      stub_request(:post, "#{SpecSupport::BASE}/v1/payments")
        .with do |req|
        captured = req
        true
      end
        .to_return(status: 201, body: payment_body, headers: json_headers)

      build_client.v1.payments.create({ amount: 1000 }, idempotency_key: "key-1")

      expect(captured.headers["Content-Type"]).to eq("application/json")
      expect(captured.headers["Idempotency-Key"]).to eq("key-1")
      expect(captured.body).to eq('{"amount":1000}')
    end

    it "merges per-call custom headers" do
      captured = nil
      stub_request(:get, "#{SpecSupport::BASE}/v1/payments/pay_1")
        .with do |req|
        captured = req.headers
        true
      end
        .to_return(status: 200, body: payment_body, headers: json_headers)

      build_client.v1.payments.retrieve("pay_1", opts: { headers: { "X-Trace" => "t-1" } })
      expect(captured["X-Trace"]).to eq("t-1")
    end

    it "never lets a per-call custom header override a reserved header, any casing" do
      captured = nil
      stub_request(:get, "#{SpecSupport::BASE}/v1/payments/pay_1")
        .with do |req|
        captured = req.headers
        true
      end
        .to_return(status: 200, body: payment_body, headers: json_headers)

      build_client.v1.payments.retrieve(
        "pay_1",
        opts: { headers: {
          "authorization" => "Bearer evil", "HOST" => "evil.example",
          "x-api-version" => "9999-99-99", "X-REQUEST-ID" => "fake-id",
          "Idempotency-Key" => "attacker-supplied"
        } }
      )

      expect(captured["Authorization"]).to eq("Bearer #{SpecSupport::API_KEY}")
      expect(captured["X-Api-Version"]).to eq(PearlPay::API_VERSION)
      expect(captured["X-Request-Id"]).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
      injected_values = captured.to_a.flatten
      %w[evil.example 9999-99-99 fake-id attacker-supplied].each do |bad_value|
        expect(injected_values).not_to include(bad_value)
      end
    end

    it "rejects unknown per-call options locally" do
      expect { build_client.v1.payments.retrieve("pay_1", opts: { retries: 5 }) }
        .to raise_error(ArgumentError, /unknown option/)
      expect(WebMock).not_to have_requested(:get, %r{/v1/payments})
    end

    it "escapes path ids" do
      stub = stub_request(:get, "#{SpecSupport::BASE}/v1/payments/pay%2F..%2Fetc")
             .to_return(status: 200, body: payment_body, headers: json_headers)
      build_client.v1.payments.retrieve("pay/../etc")
      expect(stub).to have_been_requested
    end

    it "encodes query filters and drops nils" do
      stub = stub_request(:get, "#{SpecSupport::BASE}/v1/payments?status=succeeded&page=2")
             .to_return(status: 200, body: JSON.generate(object: "list", data: [], meta: {}),
                        headers: json_headers)
      build_client.v1.payments.list(status: "succeeded", page: 2, from: nil)
      expect(stub).to have_been_requested
    end
  end

  describe "signing policy" do
    it "disbursements.create raises ConfigurationError locally without a signing secret" do
      expect do
        build_client.v1.disbursements.create({ amount: 1000 }, idempotency_key: "k")
      end.to raise_error(PearlPay::ConfigurationError, /signing_secret/)
      expect(WebMock).not_to have_requested(:post, %r{/v1/disbursements})
    end

    it "disbursements.create signs when the secret is configured" do
      captured = nil
      stub_request(:post, "#{SpecSupport::BASE}/v1/disbursements")
        .with do |req|
        captured = req
        true
      end
        .to_return(status: 201, body: JSON.generate(id: "dis_1", object: "disbursement"),
                   headers: json_headers)

      client = build_client(signing_secret: SpecSupport::SIGNING_SECRET)
      client.v1.disbursements.create({ amount: 1000 }, idempotency_key: "k")

      ts = captured.headers["X-Request-Timestamp"]
      nonce = captured.headers["X-Request-Nonce"]
      expect(ts.to_i).to be_within(5).of(Time.now.to_i)
      expect(nonce).to match(/\A\h{32}\z/)
      expect(captured.headers["X-Signature"]).to eq(
        PearlPay::RequestSignature.signature(
          secret: SpecSupport::SIGNING_SECRET, body: captured.body,
          timestamp: ts.to_i, nonce: nonce
        )
      )
    end

    it "payments.create signs iff a signing secret is configured" do
      requests = []
      stub_request(:post, "#{SpecSupport::BASE}/v1/payments")
        .with do |req|
        requests << req.headers
        true
      end
        .to_return(status: 201, body: payment_body, headers: json_headers)

      build_client.v1.payments.create({ amount: 1000 }, idempotency_key: "k1")
      build_client(signing_secret: SpecSupport::SIGNING_SECRET)
        .v1.payments.create({ amount: 1000 }, idempotency_key: "k2")

      expect(requests[0]).not_to have_key("X-Signature")
      expect(requests[1]).to have_key("X-Signature")
    end

    it "GETs are never signed even with a secret configured" do
      captured = nil
      stub_request(:get, "#{SpecSupport::BASE}/v1/payments/pay_1")
        .with do |req|
        captured = req.headers
        true
      end
        .to_return(status: 200, body: payment_body, headers: json_headers)
      build_client(signing_secret: SpecSupport::SIGNING_SECRET).v1.payments.retrieve("pay_1")
      expect(captured).not_to have_key("X-Signature")
    end
  end

  describe "idempotency keys" do
    it "payments.create requires idempotency_key as a keyword argument" do
      expect { build_client.v1.payments.create({ amount: 1000 }) }
        .to raise_error(ArgumentError, /idempotency_key/)
    end

    it "rejects a nil or oversized key locally" do
      expect { build_client.v1.payments.create({ amount: 1 }, idempotency_key: nil) }
        .to raise_error(ArgumentError, /idempotency_key/)
      expect { build_client.v1.payments.create({ amount: 1 }, idempotency_key: "x" * 256) }
        .to raise_error(ArgumentError, /255/)
    end

    it "payment_links.create auto-generates a UUID when omitted, and honors an override" do
      keys = []
      stub_request(:post, "#{SpecSupport::BASE}/v1/payment_links")
        .with do |req|
        keys << req.headers["Idempotency-Key"]
        true
      end
        .to_return(status: 201, body: JSON.generate(id: "plink_1", object: "payment_link"),
                   headers: json_headers)

      client = build_client
      client.v1.payment_links.create({ title: "T" })
      client.v1.payment_links.create({ title: "T" }, idempotency_key: "mine")

      expect(keys[0]).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
      expect(keys[1]).to eq("mine")
    end

    it "reads send no Idempotency-Key" do
      captured = nil
      stub_request(:get, "#{SpecSupport::BASE}/v1/payments/pay_1")
        .with do |req|
        captured = req.headers
        true
      end
        .to_return(status: 200, body: payment_body, headers: json_headers)
      build_client.v1.payments.retrieve("pay_1")
      expect(captured).not_to have_key("Idempotency-Key")
    end
  end

  describe "response handling" do
    it "wraps success as a PearlPay::Object with last_response metadata" do
      stub_request(:get, "#{SpecSupport::BASE}/v1/payments/pay_1")
        .to_return(status: 200, body: payment_body,
                   headers: json_headers("X-Request-Id" => "srv-1"))
      payment = build_client.v1.payments.retrieve("pay_1")
      expect(payment.status).to eq("pending")
      expect(payment.last_response.http_status).to eq(200)
      expect(payment.last_response.request_id).to eq("srv-1")
      expect(payment.last_response.idempotent_replay?).to be(false)
    end

    it "exposes Idempotent-Replayed on success replays" do
      stub_request(:post, "#{SpecSupport::BASE}/v1/payments")
        .to_return(status: 201, body: payment_body,
                   headers: json_headers("Idempotent-Replayed" => "true"))
      payment = build_client.v1.payments.create({ amount: 1000 }, idempotency_key: "k")
      expect(payment.last_response.idempotent_replay?).to be(true)
    end

    it "passes wallet balances through as decimal strings, untouched (D5)" do
      stub_request(:get, "#{SpecSupport::BASE}/v1/wallets/balance")
        .to_return(status: 200,
                   body: JSON.generate(payments: { available: "10000.50", currency: "PHP" },
                                       updated_at: "2026-04-14T08:45:00Z"),
                   headers: json_headers)
      balance = build_client.v1.wallets.balance
      expect(balance.payments.available).to eq("10000.50")
      expect(balance.payments.available).to be_a(String)
    end

    it "surfaces 3xx as an error instead of following redirects" do
      stub_request(:get, "#{SpecSupport::BASE}/v1/payments/pay_1")
        .to_return(status: 302, headers: { "Location" => "https://elsewhere.example" })
      expect { build_client.v1.payments.retrieve("pay_1") }
        .to raise_error(PearlPay::APIError) { |e|
          expect(e.code).to eq("http_302")
          expect(e.http_status).to eq(302)
        }
    end

    it "raises when a 2xx body is not JSON" do
      stub_request(:get, "#{SpecSupport::BASE}/v1/payments/pay_1")
        .to_return(status: 200, body: "<html>hi</html>")
      expect { build_client.v1.payments.retrieve("pay_1") }
        .to raise_error(PearlPay::APIError, /not valid JSON/)
    end

    it "raises ConnectionError when the response exceeds the 10 MB cap" do
      stub_request(:get, "#{SpecSupport::BASE}/v1/payments/pay_1")
        .to_return(status: 200, body: "x" * ((10 * 1024 * 1024) + 1))
      expect { build_client.v1.payments.retrieve("pay_1") }
        .to raise_error(PearlPay::ConnectionError, /10 MB/)
    end

    it "maps a write timeout to PearlPay::TimeoutError, same as open/read timeouts" do
      stub_request(:post, "#{SpecSupport::BASE}/v1/payments/pay_1/void").to_raise(Net::WriteTimeout)
      expect { build_client.raw_request(:post, "/payments/pay_1/void", params: { r: 1 }) }
        .to raise_error(PearlPay::TimeoutError)
    end
  end

  describe "float rejection (client-side, before any network call)" do
    it "rejects Float amounts naming the intended integer" do
      expect { build_client.v1.payments.create({ amount: 1500.50 }, idempotency_key: "k") }
        .to raise_error(ArgumentError, /pass 150050/)
      expect { build_client.v1.payments.create({ amount: 1500.0 }, idempotency_key: "k") }
        .to raise_error(ArgumentError, /pass 1500, not 1500\.0/)
      expect(WebMock).not_to have_requested(:post, %r{/v1/payments})
    end

    it "rejects Floats nested in hashes and arrays, naming the path" do
      expect do
        build_client.v1.payments.create({ items: [{ price: 9.99 }] }, idempotency_key: "k")
      end.to raise_error(ArgumentError, /params\[:items\]\[0\]\[:price\]/)
    end

    it "rejects Floats in query filters" do
      expect { build_client.v1.payments.list(page: 1.5) }
        .to raise_error(ArgumentError, /query/)
    end

    it "passes integer and string amounts through unchanged" do
      captured = nil
      stub_request(:post, "#{SpecSupport::BASE}/v1/payments")
        .with do |req|
        captured = req.body
        true
      end
        .to_return(status: 201, body: payment_body, headers: json_headers)
      build_client.v1.payments.create({ amount: 200_000, note: "2.50" }, idempotency_key: "k")
      expect(captured).to eq('{"amount":200000,"note":"2.50"}')
    end
  end
end
