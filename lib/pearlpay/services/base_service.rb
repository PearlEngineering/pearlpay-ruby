# frozen_string_literal: true

module PearlPay
  module Services
    # Resource services contain paths, verbs, params, and per-operation
    # metadata (retry_class, signing, idempotency) only. Every call goes
    # through the shared Requestor pipeline.
    #
    # Every public method reserves the +opts:+ keyword for per-call options
    # (idempotency_key:, headers:, open_timeout:, read_timeout:,
    # max_network_retries:); on +list+ methods all other keywords are query
    # filters passed through to the server untouched.
    class BaseService
      def initialize(requestor)
        @requestor = requestor
        freeze
      end

      private

      def request(key, path_params: {}, params: nil, query: nil, opts: {})
        meta = self.class::OPERATIONS.fetch(key)
        path = meta[:path].gsub(/\{(\w+)\}/) do
          Util.path_escape(path_params.fetch(Regexp.last_match(1).to_sym))
        end
        operation = Operation.new(
          resource: self.class::RESOURCE, name: key.to_s,
          method: meta[:method], path: path,
          retry_class: meta[:retry_class], signing: meta[:signing],
          idempotency: meta[:idempotency], read_timeout: meta[:read_timeout]
        )
        @requestor.execute(operation, params: params, query: query, opts: opts)
      end

      def with_key(opts, idempotency_key)
        idempotency_key.nil? ? opts : opts.merge(idempotency_key: idempotency_key)
      end
    end
  end
end
