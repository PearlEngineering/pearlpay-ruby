# frozen_string_literal: true

module PearlPay
  module Services
    module V1
      class PaymentLinks < BaseService
        RESOURCE = "payment_links"

        OPERATIONS = {
          create: { method: "POST", path: "/payment_links",
                    retry_class: :idempotent_transport_only, signing: :never,
                    idempotency: :auto },
          list: { method: "GET", path: "/payment_links",
                  retry_class: :read, signing: :never, idempotency: :none },
          retrieve: { method: "GET", path: "/payment_links/{id}",
                      retry_class: :read, signing: :never, idempotency: :none },
          update: { method: "PATCH", path: "/payment_links/{id}",
                    retry_class: :natural, signing: :never, idempotency: :none },
          disable: { method: "POST", path: "/payment_links/{id}/disable",
                     retry_class: :natural, signing: :never, idempotency: :none },
          clone: { method: "POST", path: "/payment_links/{id}/clone",
                   retry_class: :never, signing: :never, idempotency: :none },
          checkout_url: { method: "POST", path: "/payment_links/{id}/checkout_url",
                          retry_class: :idempotent_transport_only, signing: :never,
                          idempotency: :required, read_timeout: 30 }
        }.freeze

        # POST /v1/payment_links — when the caller omits idempotency_key the
        # SDK auto-generates one UUID per logical call, stable across its own
        # internal retries (D2). Callers may override.
        def create(params, idempotency_key: nil, opts: {})
          request(:create, params: params, opts: with_key(opts, idempotency_key))
        end

        # Cursor pagination: limit (1-100, default 25) / starting_after
        # (a plink_ id) plus filters.
        def list(opts: {}, **filters)
          request(:list, query: filters, opts: opts)
        end

        def retrieve(id, opts: {})
          request(:retrieve, path_params: { id: id }, opts: opts)
        end

        def update(id, params, opts: {})
          request(:update, path_params: { id: id }, params: params, opts: opts)
        end

        def disable(id, opts: {})
          request(:disable, path_params: { id: id }, opts: opts)
        end

        # Never retried: a clone mints a duplicate link server-side.
        def clone(id, params = {}, opts: {})
          request(:clone, path_params: { id: id }, params: params, opts: opts)
        end

        # POST /v1/payment_links/{id}/checkout_url — creates a real payment;
        # idempotency_key is a required argument (D2).
        def checkout_url(id, params, idempotency_key:, opts: {})
          request(:checkout_url, path_params: { id: id }, params: params,
                                 opts: with_key(opts, idempotency_key))
        end
      end
    end
  end
end
