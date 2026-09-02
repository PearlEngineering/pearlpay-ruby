# frozen_string_literal: true

module PearlPay
  module Services
    module V1
      class Disbursements < BaseService
        RESOURCE = "disbursements"

        OPERATIONS = {
          create: { method: "POST", path: "/disbursements",
                    retry_class: :idempotent_transport_only, signing: :required,
                    idempotency: :required },
          retrieve: { method: "GET", path: "/disbursements/{id}",
                      retry_class: :read, signing: :never, idempotency: :none },
          list: { method: "GET", path: "/disbursements",
                  retry_class: :read, signing: :never, idempotency: :none }
        }.freeze

        # POST /v1/disbursements — request signing is REQUIRED: a client
        # without signing_secret raises PearlPay::ConfigurationError locally,
        # with no network request. idempotency_key is a required argument.
        def create(params, idempotency_key:, opts: {})
          request(:create, params: params, opts: with_key(opts, idempotency_key))
        end

        def retrieve(id, opts: {})
          request(:retrieve, path_params: { id: id }, opts: opts)
        end

        def list(opts: {}, **filters)
          request(:list, query: filters, opts: opts)
        end
      end
    end
  end
end
