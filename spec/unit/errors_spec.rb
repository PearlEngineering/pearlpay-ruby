# frozen_string_literal: true

require "spec_helper"

RSpec.describe PearlPay::APIError do
  describe ".classify (code + HTTP status only, never message text)" do
    {
      [400, "invalid_json"] => PearlPay::InvalidRequestError,
      [400, "parameter_missing"] => PearlPay::InvalidRequestError,
      [400, "idempotency_required"] => PearlPay::InvalidRequestError,
      [400, "missing_signing_headers"] => PearlPay::InvalidRequestError,
      [400, "invalid_parameter"] => PearlPay::ValidationError,
      [400, "missing_parameter"] => PearlPay::ValidationError,
      [401, "unauthorized"] => PearlPay::AuthenticationError,
      [401, "invalid_signature"] => PearlPay::SignatureError,
      [403, "forbidden"] => PearlPay::PermissionError,
      [403, "forbidden_ip"] => PearlPay::PermissionError,
      [403, "test_key_not_permitted"] => PearlPay::PermissionError,
      [404, "not_found"] => PearlPay::NotFoundError,
      [404, "payment_link_not_found"] => PearlPay::NotFoundError,
      [409, "duplicate_reference"] => PearlPay::DuplicateReferenceError,
      [409, "idempotency_conflict"] => PearlPay::IdempotencyConflictError,
      [409, "idempotency_in_progress"] => PearlPay::IdempotencyInProgressError,
      [410, "payment_link_disabled"] => PearlPay::InvalidRequestError,
      [410, "payment_link_expired"] => PearlPay::InvalidRequestError,
      [410, "payment_link_exhausted"] => PearlPay::InvalidRequestError,
      [422, "insufficient_balance"] => PearlPay::InvalidRequestError,
      [422, "no_available_provider"] => PearlPay::InvalidRequestError,
      [422, "provider_unavailable"] => PearlPay::InvalidRequestError,
      [422, "fraud_declined"] => PearlPay::InvalidRequestError,
      [422, "create_failed"] => PearlPay::InvalidRequestError,
      [422, "invalid_parameter"] => PearlPay::ValidationError,
      [422, "missing_parameter"] => PearlPay::ValidationError,
      [429, "rate_limit_exceeded"] => PearlPay::RateLimitError,
      [500, "internal_error"] => described_class,
      [500, "provider_configuration_error"] => described_class,
      [500, "missing_ledger_accounts"] => described_class,
      [502, "upstream_failure"] => PearlPay::UpstreamError,
      [502, "http_502"] => described_class,
      [503, "http_503"] => described_class
    }.each do |(status, code), klass|
      it "maps #{status} #{code} to #{klass}" do
        expect(described_class.classify(status, code)).to eq(klass)
      end
    end

    it "keeps unknown codes tolerant (falls back on status family)" do
      expect(described_class.classify(422, "brand_new_decline_code"))
        .to eq(PearlPay::InvalidRequestError)
      expect(described_class.classify(409, "brand_new_conflict"))
        .to eq(PearlPay::ConflictError)
    end
  end

  describe "raised errors carry the envelope" do
    it "exposes message, code, http_status, request_id, details, and last_response" do
      stub_request(:post, "#{SpecSupport::BASE}/v1/payments")
        .to_return(status: 422,
                   body: error_body("insufficient_balance", "Wallet balance is insufficient.",
                                    details: { "needed" => 100 }, request_id: "rid-1"),
                   headers: json_headers)
      expect { build_client.v1.payments.create({ amount: 1 }, idempotency_key: "k") }
        .to raise_error(PearlPay::InvalidRequestError) { |e|
          expect(e.message).to eq("Wallet balance is insufficient.")
          expect(e.code).to eq("insufficient_balance")
          expect(e.http_status).to eq(422)
          expect(e.request_id).to eq("rid-1")
          expect(e.details).to eq("needed" => 100)
          expect(e.last_response.http_status).to eq(422)
        }
    end

    it "details stays nil when the key is absent" do
      stub_request(:get, "#{SpecSupport::BASE}/v1/payments/pay_x")
        .to_return(status: 404, body: error_body("not_found"), headers: json_headers)
      expect { build_client.v1.payments.retrieve("pay_x") }
        .to raise_error(PearlPay::NotFoundError) { |e| expect(e.details).to be_nil }
    end

    it "marks error replays via idempotent_replay? (error outcomes are cached 24h)" do
      stub_request(:post, "#{SpecSupport::BASE}/v1/payments")
        .to_return(status: 502, body: error_body("upstream_failure"),
                   headers: json_headers("Idempotent-Replayed" => "true"))
      expect { build_client.v1.payments.create({ amount: 1 }, idempotency_key: "k") }
        .to raise_error(PearlPay::UpstreamError) { |e|
          expect(e.idempotent_replay?).to be(true)
        }
    end

    it "exposes retry_after on RateLimitError and falls back to the SDK-generated " \
       "request_id when the server sends none" do
      stub_request(:get, "#{SpecSupport::BASE}/v1/payments")
        .to_return(status: 429, body: JSON.generate(error: { code: "rate_limit_exceeded",
                                                             message: "slow down" }),
                   headers: json_headers("Retry-After" => "60"))
      expect { build_client.v1.payments.list(opts: { max_network_retries: 0 }) }
        .to raise_error(PearlPay::RateLimitError) { |e|
          expect(e.retry_after).to eq(60)
          expect(e.request_id).to match(/\A[0-9a-f-]{36}\z/)
        }
    end

    it "synthesizes http_<status> for non-JSON load-balancer responses" do
      stub_request(:get, "#{SpecSupport::BASE}/v1/payments/pay_1")
        .to_return(status: 503, body: "<html>Service Unavailable</html>",
                   headers: { "Content-Type" => "text/html" })
      expect { build_client.v1.payments.retrieve("pay_1", opts: { max_network_retries: 0 }) }
        .to raise_error(described_class) { |e|
          expect(e.code).to eq("http_503")
          expect(e.http_status).to eq(503)
        }
    end
  end

  describe "hierarchy" do
    it "nests rescuable families as documented" do
      expect(PearlPay::SignatureError.ancestors).to include(PearlPay::AuthenticationError)
      expect(PearlPay::ValidationError.ancestors).to include(PearlPay::InvalidRequestError)
      expect(PearlPay::DuplicateReferenceError.ancestors).to include(PearlPay::ConflictError)
      expect(PearlPay::IdempotencyConflictError.ancestors).to include(PearlPay::ConflictError)
      expect(PearlPay::IdempotencyInProgressError.ancestors).to include(PearlPay::ConflictError)
      expect(PearlPay::UpstreamError.ancestors).to include(described_class)
      expect(described_class.ancestors).to include(PearlPay::Error)
      expect(PearlPay::TimeoutError.ancestors).to include(PearlPay::ConnectionError)
      expect(PearlPay::ConfigurationError.ancestors).to include(PearlPay::Error)
      expect(PearlPay::WebhookSignatureError.ancestors).to include(PearlPay::Error)
    end
  end
end
