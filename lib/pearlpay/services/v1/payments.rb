# frozen_string_literal: true

module PearlPay
  module Services
    module V1
      class Payments < BaseService
        RESOURCE = "payments"

        OPERATIONS = {
          create: { method: "POST", path: "/payments",
                    retry_class: :idempotent_transport_only, signing: :if_configured,
                    idempotency: :required, read_timeout: 30 },
          retrieve: { method: "GET", path: "/payments/{id}",
                      retry_class: :read, signing: :never, idempotency: :none },
          list: { method: "GET", path: "/payments",
                  retry_class: :read, signing: :never, idempotency: :none }
        }.freeze

        # POST /v1/payments — idempotency_key is required (D2: the SDK never
        # generates keys for money movement). Signed iff a signing_secret is
        # configured.
        def create(params, idempotency_key:, opts: {})
          request(:create, params: params, opts: with_key(opts, idempotency_key))
        end

        def retrieve(id, opts: {})
          request(:retrieve, path_params: { id: id }, opts: opts)
        end

        # Offset pagination: page/per_page (1-100, default 20) plus filters
        # (from, to, status, payment_channel, query).
        def list(opts: {}, **filters)
          request(:list, query: filters, opts: opts)
        end
      end
    end
  end
end
