# frozen_string_literal: true

# PearlPay Ruby SDK — the official client for PearlPay's canonical /v1
# merchant API. Stdlib only: no runtime dependencies.
#
#   client = PearlPay::Client.new(api_key: ENV.fetch("PEARLPAY_API_KEY"))
#   payment = client.v1.payments.create(
#     { merchant_reference_id: "ORDER-1", amount: 150_000, payment_channel: "qrph" },
#     idempotency_key: "order-1-attempt-1"
#   )
#
# There is deliberately no global configuration (no PearlPay.api_key=):
# construct a Client and share that one frozen instance across threads.
module PearlPay
end

require_relative "pearlpay/version"
require_relative "pearlpay/errors"
require_relative "pearlpay/util"
require_relative "pearlpay/instrumentation"
require_relative "pearlpay/configuration"
require_relative "pearlpay/request_options"
require_relative "pearlpay/object"
require_relative "pearlpay/response"
require_relative "pearlpay/list_object"
require_relative "pearlpay/request_signature"
require_relative "pearlpay/webhook"
require_relative "pearlpay/retry_policy"
require_relative "pearlpay/http/client"
require_relative "pearlpay/http/net_http_client"
require_relative "pearlpay/requestor"
require_relative "pearlpay/services/base_service"
require_relative "pearlpay/services/v1/payments"
require_relative "pearlpay/services/v1/disbursements"
require_relative "pearlpay/services/v1/disbursement_rails"
require_relative "pearlpay/services/v1/partners"
require_relative "pearlpay/services/v1/wallets"
require_relative "pearlpay/services/v1/payment_links"
require_relative "pearlpay/services/v1/webhook_endpoints"
require_relative "pearlpay/services/v1/api_keys"
require_relative "pearlpay/services/v1_services"
require_relative "pearlpay/client"
