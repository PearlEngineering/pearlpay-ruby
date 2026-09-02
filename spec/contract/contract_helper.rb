# frozen_string_literal: true

require "spec_helper"
require "yaml"
require "json_schemer"

# Test-time contract gate: fixtures and captured requests are validated
# against the vendored PearlPay OpenAPI 3.1 document. The spec is never used
# to code-generate services.
module ContractSupport
  OPENAPI_PATH = File.expand_path("openapi.yaml", __dir__)

  module_function

  def document
    @document ||= YAML.safe_load_file(OPENAPI_PATH, aliases: true)
  end

  def schemer
    @schemer ||= JSONSchemer.openapi(document)
  end

  def paths
    document.fetch("paths")
  end

  def spec_operation(verb, path)
    operation = paths.dig(path, verb.downcase)
    raise "openapi.yaml has no #{verb} #{path}" unless operation

    operation
  end

  # JSON-pointer escaping plus URI-fragment encoding for the {id} braces.
  def pointer_escape(segment)
    segment.gsub("~", "~0").gsub("/", "~1").gsub("{", "%7B").gsub("}", "%7D")
  end

  def request_schema(verb, path)
    pointer = "#/paths/#{pointer_escape(path)}/#{verb.downcase}/requestBody/content/application~1json/schema"
    schemer.ref(pointer)
  end

  def response_schema(verb, path, status)
    pointer = "#/paths/#{pointer_escape(path)}/#{verb.downcase}/responses/#{status}/" \
              "content/application~1json/schema"
    schemer.ref(pointer)
  end

  def request_example(verb, path)
    content = spec_operation(verb, path).dig("requestBody", "content", "application/json")
    content && example_from(content)
  end

  def response_example(verb, path, status)
    content = spec_operation(verb, path).dig("responses", status.to_s, "content", "application/json")
    content && example_from(content)
  end

  def example_from(content)
    return content["example"] if content["example"]

    first = (content["examples"] || {}).values.first
    first && first["value"]
  end

  def has_request_body?(verb, path)
    !spec_operation(verb, path).dig("requestBody", "content", "application/json").nil?
  end

  def validate!(schema, instance, context)
    errors = schema.validate(instance).map { |e| e.fetch("error") }.first(5)
    raise "#{context} does not validate against openapi.yaml:\n  #{errors.join("\n  ")}" unless errors.empty?

    true
  end
end
