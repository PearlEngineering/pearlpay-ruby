# frozen_string_literal: true

module PearlPay
  # The /v1 service surface: client.v1.payments, client.v1.disbursements, ...
  class V1Services
    SERVICE_CLASSES = {
      payments: -> { Services::V1::Payments },
      disbursements: -> { Services::V1::Disbursements },
      disbursement_rails: -> { Services::V1::DisbursementRails },
      partners: -> { Services::V1::Partners },
      wallets: -> { Services::V1::Wallets },
      payment_links: -> { Services::V1::PaymentLinks },
      webhook_endpoints: -> { Services::V1::WebhookEndpoints },
      api_keys: -> { Services::V1::ApiKeys }
    }.freeze

    attr_reader :payments, :disbursements, :disbursement_rails, :partners,
                :wallets, :payment_links, :webhook_endpoints, :api_keys

    def initialize(requestor)
      @payments = Services::V1::Payments.new(requestor)
      @disbursements = Services::V1::Disbursements.new(requestor)
      @disbursement_rails = Services::V1::DisbursementRails.new(requestor)
      @partners = Services::V1::Partners.new(requestor)
      @wallets = Services::V1::Wallets.new(requestor)
      @payment_links = Services::V1::PaymentLinks.new(requestor)
      @webhook_endpoints = Services::V1::WebhookEndpoints.new(requestor)
      @api_keys = Services::V1::ApiKeys.new(requestor)
      freeze
    end

    # Every declared operation, keyed "resource.name" — the contract suite and
    # the vendored-spec refresh gate compare this registry against openapi.yaml.
    def self.operations
      SERVICE_CLASSES.each_with_object({}) do |(_key, klass), registry|
        service = klass.call
        service::OPERATIONS.each do |name, meta|
          registry["#{service::RESOURCE}.#{name}"] = meta
        end
      end
    end
  end
end
