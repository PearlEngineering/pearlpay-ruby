# frozen_string_literal: true

require_relative "contract_helper"

# rake openapi:vendor only rewrites the header and absolutizes guide links
# (see Rakefile). Everything else scrubbed for the public flip — the
# local-development row, ProviderCapability, bin/rails, the dead
# design-and-stripe-parity.md link — was a one-time hand edit of this vendored
# snapshot, because the upstream source still carries them. The next real
# vendor refresh pulls from that source verbatim, so if these ever reappear
# here it means either the source regressed or someone re-vendored without
# re-applying the scrub — either way, a human needs to look, not CI silently
# passing.
RSpec.describe "vendored OpenAPI spec hygiene" do
  let(:raw) { File.read(ContractSupport::OPENAPI_PATH, encoding: "UTF-8") }

  it "has no relative /api-docs links (only resolve inside the main API app)" do
    expect(raw).not_to match(%r{[(\s]/api-docs/})
  end

  it "has no internal backend/implementation references" do
    ["bin/rails", "ProviderCapability", "localhost:3000", "in this codebase"].each do |leak|
      expect(raw).not_to include(leak), "found internal-detail leak: #{leak.inspect}"
    end
  end

  it "has no dead design-and-stripe-parity.md link" do
    expect(raw).not_to include("design-and-stripe-parity.md")
  end
end
