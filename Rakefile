# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "rubocop/rake_task"

RSpec::Core::RakeTask.new(:spec)
RuboCop::RakeTask.new(:rubocop)

task default: %i[spec rubocop]

namespace :openapi do
  desc "Refresh the vendored OpenAPI spec from the PearlPay API and fail on unknown operations. " \
       "Source: PEARLPAY_OPENAPI_SOURCE (a file path, or a URL to /api-docs/openapi.yaml)."
  task :vendor do
    require "digest"
    require "yaml"
    require "uri"
    require_relative "lib/pearlpay"

    source = ENV.fetch("PEARLPAY_OPENAPI_SOURCE", nil) or
      abort "Set PEARLPAY_OPENAPI_SOURCE to a file path or URL for the openapi.yaml"

    contents =
      if source.match?(%r{\Ahttps?://})
        require "net/http"
        uri = URI.parse(source)
        response = Net::HTTP.get_response(uri)
        abort "Fetching #{source} returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
        response.body
      else
        File.read(source)
      end

    document = YAML.safe_load(contents, aliases: true)
    spec_ops = document.fetch("paths").flat_map do |path, verbs|
      verbs.slice("get", "post", "patch", "put", "delete")
           .map { |verb, _| "#{verb.upcase} #{path}" }
    end.sort

    sdk_ops = PearlPay::V1Services.operations.map do |_key, meta|
      "#{meta[:method]} #{meta[:path]}"
    end.sort

    unknown = spec_ops - sdk_ops
    unless unknown.empty?
      abort "openapi.yaml declares operations the SDK does not implement:\n  " \
            "#{unknown.join("\n  ")}\nImplement them (or update the registry) before vendoring."
    end

    vendor_header = <<~HEADER
      # This file is vendored from the PearlPay API's canonical OpenAPI spec.
      # Refresh it with:
      #
      #   PEARLPAY_OPENAPI_SOURCE=/path/to/openapi.yaml bundle exec rake openapi:vendor
      #
      # Do not hand-edit — edit the source spec and re-vendor instead.
    HEADER
    contents = vendor_header + contents.sub(/\A(?:#.*\n)+/, "")

    target = File.expand_path("spec/contract/openapi.yaml", __dir__)
    File.write(target, contents)
    sha = Digest::SHA256.hexdigest(contents)
    File.write("#{target}.sha256", "#{sha}  openapi.yaml\n")
    puts "Vendored #{source} -> spec/contract/openapi.yaml (sha256 #{sha[0, 12]}…)"
  end
end
