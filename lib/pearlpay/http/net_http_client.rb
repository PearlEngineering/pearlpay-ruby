# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"

module PearlPay
  module Http
    # stdlib Net::HTTP transport. TLS verification is always on (VERIFY_PEER,
    # no toggle). Redirects are not followed — 3xx responses are returned
    # as-is for the Requestor to surface as errors. Response bodies are
    # capped at 10 MB before parsing.
    class NetHttpClient < Client
      MAX_RESPONSE_BYTES = 10 * 1024 * 1024

      VERB_CLASSES = {
        "GET" => Net::HTTP::Get,
        "POST" => Net::HTTP::Post,
        "PATCH" => Net::HTTP::Patch,
        "PUT" => Net::HTTP::Put,
        "DELETE" => Net::HTTP::Delete
      }.freeze

      class ResponseTooLarge < StandardError; end

      def execute(method:, uri:, headers:, body:, open_timeout:, read_timeout:)
        request_class = VERB_CLASSES.fetch(method) do
          raise ArgumentError, "unsupported HTTP method: #{method}"
        end

        http = Net::HTTP.new(uri.host, uri.port)
        http.open_timeout = open_timeout
        http.read_timeout = read_timeout
        if uri.scheme == "https"
          http.use_ssl = true
          http.verify_mode = OpenSSL::SSL::VERIFY_PEER
          http.min_version = OpenSSL::SSL::TLS1_2_VERSION
        end

        request = request_class.new(uri.request_uri)
        headers.each { |key, value| request[key] = value }
        request.body = body if body

        status = nil
        response_headers = nil
        buffer = +""
        http.start do |conn|
          conn.request(request) do |response|
            status = response.code.to_i
            response_headers = response.each_header.to_h
            response.read_body do |chunk|
              buffer << chunk
              raise ResponseTooLarge if buffer.bytesize > MAX_RESPONSE_BYTES
            end
          end
        end

        Response.new(status: status, headers: response_headers, body: buffer)
      rescue ResponseTooLarge
        raise PearlPay::ConnectionError,
              "response body exceeded the #{MAX_RESPONSE_BYTES / (1024 * 1024)} MB cap"
      end
    end
  end
end
