# frozen_string_literal: true

require "spec_helper"

RSpec.describe "The /v1 API surface" do
  # SDK method -> [verb, path template, retry_class, signing, idempotency]
  expected_surface = {
    "payments.create" => ["POST", "/payments", :idempotent_transport_only, :if_configured, :required],
    "payments.retrieve" => ["GET", "/payments/{id}", :read, :never, :none],
    "payments.list" => ["GET", "/payments", :read, :never, :none],
    "disbursements.create" => ["POST", "/disbursements", :idempotent_transport_only, :required, :required],
    "disbursements.retrieve" => ["GET", "/disbursements/{id}", :read, :never, :none],
    "disbursements.list" => ["GET", "/disbursements", :read, :never, :none],
    "disbursement_rails.list" => ["GET", "/disbursements/rails", :read, :never, :none],
    "disbursement_rails.partners" => ["GET", "/disbursements/rails/{code}/partners", :read, :never, :none],
    "partners.list" => ["GET", "/partners", :read, :never, :none],
    "wallets.balance" => ["GET", "/wallets/balance", :read, :never, :none],
    "payment_links.create" => ["POST", "/payment_links", :idempotent_transport_only, :never, :auto],
    "payment_links.list" => ["GET", "/payment_links", :read, :never, :none],
    "payment_links.retrieve" => ["GET", "/payment_links/{id}", :read, :never, :none],
    "payment_links.update" => ["PATCH", "/payment_links/{id}", :natural, :never, :none],
    "payment_links.disable" => ["POST", "/payment_links/{id}/disable", :natural, :never, :none],
    "payment_links.clone" => ["POST", "/payment_links/{id}/clone", :never, :never, :none],
    "payment_links.checkout_url" => ["POST", "/payment_links/{id}/checkout_url",
                                     :idempotent_transport_only, :never, :required],
    "webhook_endpoints.create" => ["POST", "/webhook_endpoints", :never, :never, :none],
    "webhook_endpoints.list" => ["GET", "/webhook_endpoints", :read, :never, :none],
    "webhook_endpoints.activate" => ["POST", "/webhook_endpoints/{id}/activate", :natural, :never, :none],
    "webhook_endpoints.rotate_signing_secret" => ["POST", "/webhook_endpoints/{id}/rotate_signing_secret",
                                                  :never, :never, :none],
    "api_keys.rotate_signing_secret" => ["POST", "/api_keys/{id}/rotate_signing_secret",
                                         :never, :never, :none]
  }.freeze

  it "declares exactly the 22 fixed operations (plus caller-shaped raw_request)" do
    expect(PearlPay::V1Services.operations.keys).to match_array(expected_surface.keys)
  end

  expected_surface.each do |name, (verb, path, retry_class, signing, idempotency)|
    it "#{name} is #{verb} #{path} [#{retry_class}/#{signing}/#{idempotency}]" do
      meta = PearlPay::V1Services.operations.fetch(name)
      expect(meta[:method]).to eq(verb)
      expect(meta[:path]).to eq(path)
      expect(meta[:retry_class]).to eq(retry_class)
      expect(meta[:signing]).to eq(signing)
      expect(meta[:idempotency]).to eq(idempotency)
    end
  end

  it "uses the 30s read timeout for the synchronous provider-I/O creates" do
    expect(PearlPay::V1Services.operations["payments.create"][:read_timeout]).to eq(30)
    expect(PearlPay::V1Services.operations["payment_links.checkout_url"][:read_timeout]).to eq(30)
    expect(PearlPay::V1Services.operations["disbursements.create"][:read_timeout]).to be_nil
  end

  it "partners.list requires channel: and sends it as a query param" do
    stub = stub_request(:get, "#{SpecSupport::BASE}/v1/partners?channel=instapay")
           .to_return(status: 200, body: JSON.generate(object: "list", data: []),
                      headers: { "Content-Type" => "application/json" })
    build_client.v1.partners.list(channel: "instapay")
    expect(stub).to have_been_requested
    expect { build_client.v1.partners.list }.to raise_error(ArgumentError)
  end

  it "payment_links.update sends a PATCH body" do
    stub = stub_request(:patch, "#{SpecSupport::BASE}/v1/payment_links/plink_1")
           .with(body: '{"title":"New"}')
           .to_return(status: 200, body: JSON.generate(id: "plink_1"),
                      headers: { "Content-Type" => "application/json" })
    build_client.v1.payment_links.update("plink_1", { title: "New" })
    expect(stub).to have_been_requested
  end

  it "checkout_url requires idempotency_key and posts to the link path" do
    stub = stub_request(:post, "#{SpecSupport::BASE}/v1/payment_links/plink_1/checkout_url")
           .to_return(status: 201, body: JSON.generate(id: "pay_9"),
                      headers: { "Content-Type" => "application/json" })
    build_client.v1.payment_links.checkout_url(
      "plink_1", { merchant_reference_id: "R-1" }, idempotency_key: "k"
    )
    expect(stub).to have_been_requested
    expect do
      build_client.v1.payment_links.checkout_url("plink_1", { merchant_reference_id: "R-1" })
    end.to raise_error(ArgumentError, /idempotency_key/)
  end
end
