# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Thread-safety smoke" do
  it "one client instance is safely shared across threads" do
    stub_request(:get, %r{#{SpecSupport::BASE}/v1/payments/pay_\d+})
      .to_return do |request|
        id = request.uri.path.split("/").last
        { status: 200, body: JSON.generate(id: id, object: "payment"),
          headers: { "Content-Type" => "application/json" } }
      end

    events = Queue.new
    surfaces = Queue.new
    client = build_client(instrumentation: ->(event) { events << event })

    results = Array.new(8) do |worker|
      Thread.new do
        surfaces << [client.v1.object_id, client.v1.payments.object_id]
        Array.new(10) { |n| client.v1.payments.retrieve("pay_#{worker}#{n}").id }
      end
    end.flat_map(&:value)

    expect(results.size).to eq(80)
    expect(results.uniq.size).to eq(80)
    results.each_with_index do |id, _i|
      expect(id).to match(/\Apay_\d+\z/)
    end
    expect(events.size).to eq(80)
    expect(client).to be_frozen
    expect(surfaces.size).to eq(8)
    expect(Array.new(8) { surfaces.pop }.uniq.size).to eq(1)
  end
end
