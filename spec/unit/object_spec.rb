# frozen_string_literal: true

require "spec_helper"

RSpec.describe PearlPay::Object do
  let(:data) do
    {
      "id" => "pay_1", "status" => "some_future_status", "amount" => 200_000,
      "customer" => { "first_name" => "Ana", "tags" => [{ "k" => "v" }] },
      "checkout_url" => nil, "brand_new_field" => "passes through"
    }
  end
  let(:object) { described_class.new(data) }

  it "supports method access" do
    expect(object.id).to eq("pay_1")
    expect(object.amount).to eq(200_000)
  end

  it "supports string and symbol indexing" do
    expect(object["id"]).to eq("pay_1")
    expect(object[:id]).to eq("pay_1")
  end

  it "wraps nested hashes lazily, and hashes inside arrays" do
    expect(object.customer).to be_a(described_class)
    expect(object.customer.first_name).to eq("Ana")
    expect(object.customer.tags.first).to be_a(described_class)
    expect(object.customer.tags.first.k).to eq("v")
  end

  it "passes unknown fields and unknown enum values through untouched" do
    expect(object.brand_new_field).to eq("passes through")
    expect(object.status).to eq("some_future_status")
  end

  it "returns nil for null fields but raises NoMethodError for absent ones" do
    expect(object.checkout_url).to be_nil
    expect { object.no_such_field }.to raise_error(NoMethodError)
    expect(object[:no_such_field]).to be_nil
  end

  it "refuses writes" do
    expect { object.status = "paid" }.to raise_error(NoMethodError, /read-only/)
  end

  it "answers respond_to? and key? from the data" do
    expect(object).to respond_to(:id)
    expect(object).not_to respond_to(:nope)
    expect(object.key?(:id)).to be(true)
    expect(object.key?("nope")).to be(false)
  end

  it "digs through nesting and arrays" do
    expect(object.dig(:customer, :tags, 0, :k)).to eq("v")
    expect(object.dig(:customer, :missing)).to be_nil
  end

  it "round-trips to_h and to_json" do
    expect(object.to_h).to eq(data)
    expect(JSON.parse(object.to_json)).to eq(data)
  end

  it "returns a frozen to_h that cannot mutate the object's internal state" do
    result = object.to_h
    expect(result).to be_frozen
    expect(result["customer"]).to be_frozen
    expect { result["id"] = "tampered" }.to raise_error(FrozenError)
    expect(object.id).to eq("pay_1")
  end

  it "is immutable from construction, not just via to_h — scalar accessors " \
     "cannot mutate internal state even before to_h is ever called" do
    fresh = described_class.new({ "id" => "pay_1" })
    expect(fresh.id).to be_frozen
    expect { fresh.id << "-tampered" }.to raise_error(FrozenError)
    expect(fresh.id).to eq("pay_1")
  end

  it "copies on construction and never freezes or shares identity with the " \
     "caller's own input" do
    input = { "id" => +"pay_2", "nested" => { "k" => +"v" } }
    wrapped = described_class.new(input)

    expect(input).not_to be_frozen
    expect(input["id"]).not_to be_frozen
    expect(input["nested"]).not_to be_frozen

    input["id"] << "-mutated-by-caller"
    expect(wrapped.id).to eq("pay_2")
  end

  it "returns a frozen array from array-valued fields" do
    expect(object.customer.tags).to be_frozen
  end

  it "redacts secret-shaped values from inspect, at any nesting depth" do
    secretive = described_class.new(
      "id" => "we_1",
      "signing_secret" => "whsec_test_fixture_not_a_real_secret",
      "rotated" => { "signing_secret" => "whsig_test_fixture_not_a_real_secret" },
      "keys" => [{ "value" => "sk_live_#{'cd' * 24}" }, { "value" => "sk_test_#{'ab' * 24}" }]
    )
    inspected = secretive.inspect
    %w[whsec_ whsig_ sk_live_ sk_test_].each do |marker|
      expect(inspected).not_to include(marker)
    end
    expect(inspected).to include("[REDACTED]")
    expect(inspected).to include("we_1")
  end

  it "propagates last_response into nested objects" do
    response = PearlPay::APIResponse.new(http_status: 200, headers: {})
    wrapped = described_class.new(data, response)
    expect(wrapped.customer.last_response).to be(response)
  end
end

RSpec.describe PearlPay::APIResponse do
  it "sanitizes headers and derives request_id and idempotent_replay?" do
    response = described_class.new(
      http_status: 201,
      headers: { "X-Request-Id" => "rid-9", "Idempotent-Replayed" => "true",
                 "Set-Cookie" => "session=secret", "Content-Type" => "application/json" }
    )
    expect(response.request_id).to eq("rid-9")
    expect(response.idempotent_replay?).to be(true)
    expect(response.headers).not_to have_key("set-cookie")
    expect(response.headers["content-type"]).to eq("application/json")
    expect(response).to be_frozen
  end

  it "allowlists response headers — anything not explicitly known-safe is dropped, " \
     "not just the historically-denylisted ones" do
    response = described_class.new(
      http_status: 200,
      headers: { "Content-Type" => "application/json", "X-Served-By" => "cache-mnl1",
                 "Server" => "nginx/1.27", "Set-Cookie" => "session=secret" }
    )
    expect(response.headers.keys).to contain_exactly("content-type")
  end
end
