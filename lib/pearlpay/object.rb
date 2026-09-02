# frozen_string_literal: true

module PearlPay
  # Tolerant read-only wrapper over a parsed JSON hash. Method access and
  # string/symbol indexing; nested hashes wrap lazily; unknown fields and
  # unknown enum values pass through untouched. No writes.
  class Object
    # Value-shape markers for fields that must never appear in logs or
    # inspect output, independent of field name — responses such as
    # signing-secret rotation or webhook-endpoint creation carry these
    # directly in the JSON body.
    SECRET_VALUE_MARKERS = %w[sk_live_ sk_test_ whsig_ whsec_].freeze

    def initialize(data, last_response = nil)
      raise ArgumentError, "PearlPay::Object wraps a Hash" unless data.is_a?(Hash)

      # Deep-copied and deep-frozen up front, not lazily: every accessor,
      # including scalar field access, must return an already-immutable
      # value from the moment this object exists — a copy of the caller's
      # data, never the caller's own objects.
      @data = deep_dup_freeze(data)
      @last_response = last_response
    end

    attr_reader :last_response

    def [](key)
      wrap(raw_fetch(key.to_s))
    end

    def key?(key)
      @data.key?(key.to_s)
    end
    alias include? key?

    def dig(*keys)
      keys.reduce(self) do |value, key|
        case value
        when Object then value[key]
        when Array then key.is_a?(Integer) ? value[key] : (return nil)
        else return nil
        end
      end
    end

    # Plain deep data (the parsed JSON, unwrapped). @data is already a
    # deep-frozen copy owned by this object, so this is safe to return
    # directly — mutating attempts on the result raise FrozenError rather
    # than silently succeeding or corrupting internal state.
    def to_h
      @data
    end
    alias to_hash to_h

    def to_json(*)
      JSON.generate(@data, *)
    end

    def ==(other)
      other.is_a?(Object) && other.to_h == @data
    end
    alias eql? ==

    def hash
      @data.hash
    end

    def inspect
      "#<#{self.class.name} #{redact(@data).inspect}>"
    end

    def method_missing(name, *args, &block)
      key = name.to_s
      if key.end_with?("=")
        raise NoMethodError,
              "#{self.class.name} is read-only; cannot assign #{key.delete_suffix('=')}"
      end
      return super unless args.empty? && block.nil? && @data.key?(key)

      wrap(@data[key])
    end

    def respond_to_missing?(name, include_private = false)
      @data.key?(name.to_s) || super
    end

    private

    def raw_fetch(key)
      @data[key]
    end

    def wrap(value)
      case value
      when Hash then Object.new(value, @last_response)
      when Array then value.map { |v| wrap(v) }.freeze
      else value
      end
    end

    # Duplicates before freezing at every level, including scalars — never
    # freezes an object the caller still holds a reference to. Hash#dup and
    # Array#dup happen implicitly via transform_values/map, which always
    # build new containers; String needs an explicit #dup since freezing
    # in place would mutate the caller's own string.
    def deep_dup_freeze(value)
      case value
      when Hash then value.transform_values { |v| deep_dup_freeze(v) }.freeze
      when Array then value.map { |v| deep_dup_freeze(v) }.freeze
      when String then value.dup.freeze
      else value.freeze # Integer/Float/true/false/nil are already immutable
      end
    end

    def redact(value)
      case value
      when Hash then value.transform_values { |v| redact(v) }
      when Array then value.map { |v| redact(v) }
      when String then SECRET_VALUE_MARKERS.any? { |marker| value.include?(marker) } ? "[REDACTED]" : value
      else value
      end
    end
  end
end
