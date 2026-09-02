# frozen_string_literal: true

require "spec_helper"

RSpec.describe PearlPay::Configuration do
  def config(**overrides)
    described_class.new(api_key: SpecSupport::API_KEY, **overrides)
  end

  it "requires an api_key" do
    expect { described_class.new(api_key: nil) }.to raise_error(PearlPay::ConfigurationError)
    expect { described_class.new(api_key: "") }.to raise_error(PearlPay::ConfigurationError)
  end

  it "is frozen after construction" do
    expect(config).to be_frozen
  end

  describe "api_base normalization" do
    it "defaults to the production origin" do
      expect(config.api_base).to eq("https://api.pearlpay.io")
    end

    it "strips a trailing slash" do
      expect(config(api_base: "https://api.pearlpay.io/").api_base).to eq("https://api.pearlpay.io")
    end

    it "strips a trailing /v1 with a one-time warning" do
      warnings = []
      allow(Kernel).to receive(:warn) { |msg| warnings << msg }
      expect(config(api_base: "https://api.pearlpay.io/v1").api_base).to eq("https://api.pearlpay.io")
      config(api_base: "https://api.pearlpay.io/v1/")
      expect(warnings.grep(%r{stripping trailing /v1}).size).to eq(1)
    end

    it "keeps a non-default port" do
      expect(config(api_base: "https://api.staging.pearlpay.io:8443").api_base)
        .to eq("https://api.staging.pearlpay.io:8443")
    end

    it "rejects plain http for non-local hosts" do
      expect { config(api_base: "http://api.pearlpay.io") }
        .to raise_error(PearlPay::ConfigurationError, /https/)
    end

    it "allows plain http for localhost, 127.0.0.1, and ::1" do
      expect(config(api_base: "http://localhost:3000").api_base).to eq("http://localhost:3000")
      expect(config(api_base: "http://127.0.0.1:3000").api_base).to eq("http://127.0.0.1:3000")
      expect(config(api_base: "http://[::1]:3000").api_base).to eq("http://[::1]:3000")
    end

    it "rejects a base with a path (origin only — the SDK owns /v1)" do
      expect { config(api_base: "https://api.pearlpay.io/api") }
        .to raise_error(PearlPay::ConfigurationError, /origin only/)
    end

    it "rejects query, fragment, userinfo, and non-URL garbage" do
      expect { config(api_base: "https://api.pearlpay.io?x=1") }.to raise_error(PearlPay::ConfigurationError)
      expect { config(api_base: "https://user:pw@api.pearlpay.io") }.to raise_error(PearlPay::ConfigurationError)
      expect { config(api_base: "not a url") }.to raise_error(PearlPay::ConfigurationError)
    end
  end

  describe "option validation" do
    it "rejects negative or non-integer max_network_retries" do
      expect { config(max_network_retries: -1) }.to raise_error(PearlPay::ConfigurationError)
      expect { config(max_network_retries: 1.5) }.to raise_error(PearlPay::ConfigurationError)
      expect(config(max_network_retries: 0).max_network_retries).to eq(0)
    end

    it "rejects non-positive timeouts" do
      expect { config(open_timeout: 0) }.to raise_error(PearlPay::ConfigurationError)
      expect { config(read_timeout: -5) }.to raise_error(PearlPay::ConfigurationError)
    end

    it "rejects an instrumentation hook that is not callable" do
      expect { config(instrumentation: "log it") }.to raise_error(PearlPay::ConfigurationError)
    end
  end

  describe "redaction" do
    it "never reveals secrets in #inspect or #to_s" do
      c = config(signing_secret: SpecSupport::SIGNING_SECRET)
      [c.inspect, c.to_s].each do |text|
        expect(text).to include("[REDACTED]")
        %w[sk_live_ sk_test_ whsig_ whsec_ Bearer].each do |marker|
          expect(text).not_to include(marker)
        end
      end
    end
  end
end
