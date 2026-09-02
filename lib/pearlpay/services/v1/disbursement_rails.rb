# frozen_string_literal: true

module PearlPay
  module Services
    module V1
      class DisbursementRails < BaseService
        RESOURCE = "disbursement_rails"

        OPERATIONS = {
          list: { method: "GET", path: "/disbursements/rails",
                  retry_class: :read, signing: :never, idempotency: :none },
          partners: { method: "GET", path: "/disbursements/rails/{code}/partners",
                      retry_class: :read, signing: :never, idempotency: :none }
        }.freeze

        def list(opts: {})
          request(:list, opts: opts)
        end

        def partners(code, opts: {})
          request(:partners, path_params: { code: code }, opts: opts)
        end
      end
    end
  end
end
