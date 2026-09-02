# frozen_string_literal: true

require_relative "lib/pearlpay/version"

Gem::Specification.new do |spec|
  spec.name = "pearlpay"
  spec.version = PearlPay::VERSION
  spec.authors = ["PearlPay Engineering"]
  spec.email = ["engineering@pearlpay.io"]

  spec.summary = "Official Ruby SDK for the PearlPay /v1 merchant API"
  spec.description = "Accept payments, send disbursements, manage payment links and " \
                     "webhooks on PearlPay. Stdlib only — zero runtime dependencies."
  spec.homepage = "https://pearlpay.com"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  repo_url = "https://github.com/PearlEngineering/pearlpay-ruby"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = repo_url
  spec.metadata["changelog_uri"] = "#{repo_url}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{repo_url}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "LICENSE", "README.md", "CHANGELOG.md", "SECURITY.md"]
  spec.require_paths = ["lib"]

  # Zero runtime dependencies — stdlib only (net/http, json, openssl, digest,
  # securerandom, uri, time). This is a hard constraint; do not add any.
end
