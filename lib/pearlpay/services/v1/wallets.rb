# frozen_string_literal: true

module PearlPay
  module Services
    module V1
      class Wallets < BaseService
        RESOURCE = "wallets"

        OPERATIONS = {
          balance: { method: "GET", path: "/wallets/balance",
                     retry_class: :read, signing: :never, idempotency: :none }
        }.freeze

        # GET /v1/wallets/balance — balances are decimal STRINGS ("10000.50")
        # and pass through unchanged (approved ruling D5); the SDK never
        # converts money representations.
        def balance(opts: {})
          request(:balance, opts: opts)
        end
      end
    end
  end
end
