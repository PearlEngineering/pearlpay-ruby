# frozen_string_literal: true

require "webmock/rspec"
require "pearlpay"

module SpecSupport
  API_KEY = "sk_test_#{'ab' * 24}".freeze
  SIGNING_SECRET = "whsig_spec_signing_secret_0123456789abcdef"
  BASE = "https://api.pearlpay.io"

  attr_reader :recorded_sleeps

  def build_client(events: nil, **overrides)
    options = {
      api_key: API_KEY,
      max_network_retries: 2,
      instrumentation: events ? ->(event) { events << event } : nil
    }.merge(overrides)
    PearlPay::Client.new(**options)
  end

  def error_body(code, message = "boom", details: nil, request_id: "req-uuid-1")
    error = { code: code, message: message, request_id: request_id }
    error[:details] = details if details
    JSON.generate(error: error)
  end

  def json_headers(extra = {})
    { "Content-Type" => "application/json" }.merge(extra)
  end
end

RSpec.configure do |config|
  config.include SpecSupport

  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end
  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  config.before do
    PearlPay::Util.reset_warnings!
    # The requestor's default sleeper calls Kernel.sleep with an explicit
    # receiver; capture instead of sleeping so retry specs run instantly.
    @recorded_sleeps = []
    sleeps = @recorded_sleeps
    allow(Kernel).to receive(:sleep) { |seconds| sleeps << seconds }
  end
end
