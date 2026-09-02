# frozen_string_literal: true

module PearlPay
  module Services
    module V1
      class ApiKeys < BaseService
        RESOURCE = "api_keys"

        OPERATIONS = {
          rotate_signing_secret: { method: "POST",
                                   path: "/api_keys/{id}/rotate_signing_secret",
                                   retry_class: :never, signing: :never, idempotency: :none }
        }.freeze

        # Never retried: rotation invalidates the previous whsig_ secret
        # immediately; the new one is shown exactly once.
        def rotate_signing_secret(id, opts: {})
          request(:rotate_signing_secret, path_params: { id: id }, opts: opts)
        end
      end
    end
  end
end
