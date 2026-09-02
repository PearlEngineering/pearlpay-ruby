# frozen_string_literal: true

module PearlPay
  module Http
    # Transport interface. Implementations take one fully-built request and
    # return a PearlPay::Http::Response; they perform no retries, no auth,
    # and no parsing — that all belongs to the Requestor.
    class Client
      def execute(method:, uri:, headers:, body:, open_timeout:, read_timeout:)
        raise NotImplementedError, "#{self.class} must implement #execute"
      end
    end
  end
end
