# frozen_string_literal: true

module PearlPay
  module Services
    module V1
      class Partners < BaseService
        RESOURCE = "partners"

        OPERATIONS = {
          list: { method: "GET", path: "/partners",
                  retry_class: :read, signing: :never, idempotency: :none }
        }.freeze

        def list(channel:, opts: {})
          request(:list, query: { channel: channel }, opts: opts)
        end
      end
    end
  end
end
