# frozen_string_literal: true

require_relative "contract_helper"

RSpec.describe "OpenAPI coverage" do
  it "the SDK implements every operation the spec declares, and nothing else" do
    spec_ops = ContractSupport.paths.flat_map do |path, verbs|
      verbs.slice("get", "post", "patch", "put", "delete")
           .map { |verb, _| "#{verb.upcase} #{path}" }
    end

    sdk_ops = PearlPay::V1Services.operations.map do |_name, meta|
      "#{meta[:method]} #{meta[:path]}"
    end

    expect(sdk_ops).to match_array(spec_ops)
  end

  it "every operation's path parameters are named in the SDK path template" do
    PearlPay::V1Services.operations.each_value do |meta|
      spec_params = (ContractSupport.spec_operation(meta[:method], meta[:path])["parameters"] || [])
                    .select { |p| p.is_a?(Hash) && p["in"] == "path" }
                    .map { |p| p["name"] }
      template_params = meta[:path].scan(/\{(\w+)\}/).flatten
      expect(template_params).to match_array(spec_params),
                                 "#{meta[:method]} #{meta[:path]}: template params #{template_params} " \
                                 "!= spec path params #{spec_params}"
    end
  end
end
