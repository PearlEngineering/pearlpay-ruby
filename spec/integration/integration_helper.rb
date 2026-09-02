# frozen_string_literal: true

# Golden-path integration specs against a seeded local PearlPay API server.
# Opt-in:
#
#   PEARLPAY_INTEGRATION=1 \
#   PEARLPAY_API_BASE=http://localhost:3000 \
#   PEARLPAY_API_KEY=sk_live_... \
#   PEARLPAY_SIGNING_SECRET=whsig_... \
#   PEARLPAY_WEBHOOK_SECRET=whsec_... \
#   bundle exec rspec spec/integration
#
# Must be a live key. The API rejects a test-mode key on the money-moving
# creates — payments.create and disbursements.create — with 403
# test_key_not_permitted until a sandboxed test-mode path exists (see the
# Forbidden response in spec/contract/openapi.yaml). So a
# sk_test_ key fails golden paths 1, 2 and 3 by design, not because of an
# SDK bug: 1 and 2 are the rejected creates, and 3 (cached error replay)
# fails downstream because the 403 pre-empts idempotency caching, leaving
# nothing to replay.
#
# A live key moves real money: these examples create real payments and
# disbursements against whatever PEARLPAY_API_BASE points at, so keep it on
# your local PearlPay API server.
#
# Without PEARLPAY_INTEGRATION=1 every example is skipped (and WebMock stays
# active for the rest of the suite).
require "spec_helper"

module IntegrationSupport
  def self.enabled?
    ENV["PEARLPAY_INTEGRATION"] == "1"
  end

  def integration_client(**overrides)
    PearlPay::Client.new(
      api_key: ENV.fetch("PEARLPAY_API_KEY"),
      signing_secret: ENV.fetch("PEARLPAY_SIGNING_SECRET", nil),
      api_base: ENV.fetch("PEARLPAY_API_BASE", "http://localhost:3000"),
      **overrides
    )
  end

  def unique_reference(prefix)
    "#{prefix}-#{Time.now.to_i}-#{SecureRandom.hex(4)}"
  end
end

RSpec.configure do |config|
  config.include IntegrationSupport

  config.before(:each, :integration) do
    skip "set PEARLPAY_INTEGRATION=1 to run integration specs" unless IntegrationSupport.enabled?
    WebMock.allow_net_connect!
  end

  config.after(:each, :integration) do
    WebMock.disable_net_connect! if IntegrationSupport.enabled?
  end
end
