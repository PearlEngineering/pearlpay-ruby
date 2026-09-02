# frozen_string_literal: true

module PearlPay
  module Services
    module V1
      class WebhookEndpoints < BaseService
        RESOURCE = "webhook_endpoints"

        OPERATIONS = {
          create: { method: "POST", path: "/webhook_endpoints",
                    retry_class: :never, signing: :never, idempotency: :none },
          list: { method: "GET", path: "/webhook_endpoints",
                  retry_class: :read, signing: :never, idempotency: :none },
          activate: { method: "POST", path: "/webhook_endpoints/{id}/activate",
                      retry_class: :natural, signing: :never, idempotency: :none },
          rotate_signing_secret: { method: "POST",
                                   path: "/webhook_endpoints/{id}/rotate_signing_secret",
                                   retry_class: :never, signing: :never, idempotency: :none }
        }.freeze

        # Never retried: a retry after a lost response would mint a duplicate
        # endpoint (the server ignores Idempotency-Key here). The 201 response
        # includes signing_secret (whsec_...) exactly once — store it.
        def create(params, opts: {})
          request(:create, params: params, opts: opts)
        end

        def list(opts: {})
          request(:list, opts: opts)
        end

        def activate(id, opts: {})
          request(:activate, path_params: { id: id }, opts: opts)
        end

        # Never retried: rotation is destructive — a retry after a lost
        # response would invalidate the secret just issued.
        def rotate_signing_secret(id, opts: {})
          request(:rotate_signing_secret, path_params: { id: id }, opts: opts)
        end
      end
    end
  end
end
