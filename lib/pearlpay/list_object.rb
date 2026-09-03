# frozen_string_literal: true

module PearlPay
  # A list response. Two pagination strategies, selected from the meta shape:
  #
  # - Offset (payments, disbursements): meta has page/per_page/total/total_pages;
  #   +has_more?+ is derived (page < total_pages); next page requests page+1.
  # - Cursor (payment_links): meta has limit/has_more and, when there is a next
  #   page, next_starting_after (exposed as +next_cursor+).
  # - Unpaginated (webhook_endpoints, rails, partners): no meta —
  #   +auto_paging_each+ is plain +each+.
  #
  # Every next-page fetch goes back through the full request pipeline.
  class ListObject
    include Enumerable

    ARRAY_KEYS = %w[data rails partners].freeze

    attr_reader :last_response

    def initialize(data, last_response = nil, next_page_fetcher: nil)
      # Deep-copied and deep-frozen up front, same as PearlPay::Object: #to_h
      # must never hand back a hash the caller can mutate to corrupt this
      # list's later reads (#data, #meta, #has_more?, ...).
      @data = deep_dup_freeze(data)
      @last_response = last_response
      @next_page_fetcher = next_page_fetcher
    end

    # The array of wrapped items on this page.
    def data
      (raw_items || []).map { |item| item.is_a?(Hash) ? Object.new(item, @last_response) : item }
    end

    def each(&)
      data.each(&)
    end

    def empty?
      (raw_items || []).empty?
    end

    def meta
      m = @data["meta"]
      m.is_a?(Hash) ? Object.new(m, @last_response) : nil
    end

    def [](key)
      value = @data[key.to_s]
      value.is_a?(Hash) ? Object.new(value, @last_response) : value
    end

    def to_h
      @data
    end

    def pagination
      m = @data["meta"]
      return :none unless m.is_a?(Hash)
      return :offset if m.key?("total_pages") || m.key?("page")
      return :cursor if m.key?("has_more") || m.key?("next_starting_after")

      :none
    end

    def has_more?
      m = @data["meta"]
      case pagination
      when :offset then m["page"].to_i < m["total_pages"].to_i
      when :cursor then m["has_more"] == true
      else false
      end
    end

    # Cursor lists only: the id to pass as starting_after for the next page.
    # The server includes next_starting_after only when has_more is true.
    def next_cursor
      m = @data["meta"]
      pagination == :cursor && m ? m["next_starting_after"] : nil
    end

    # Fetches the next page through the full request pipeline; nil when done.
    def next_page
      return nil unless has_more? && @next_page_fetcher

      case pagination
      when :offset
        @next_page_fetcher.call("page" => @data["meta"]["page"].to_i + 1)
      when :cursor
        cursor = next_cursor
        return nil unless cursor

        @next_page_fetcher.call("starting_after" => cursor)
      end
    end

    # Iterates every item across all pages (plain +each+ for unpaginated lists).
    def auto_paging_each(&block)
      return enum_for(:auto_paging_each) unless block

      page = self
      while page
        page.each(&block)
        page = page.has_more? ? page.next_page : nil
      end
      self
    end

    def inspect
      "#<#{self.class.name} count=#{(raw_items || []).size} pagination=#{pagination}>"
    end

    private

    def raw_items
      key = ARRAY_KEYS.find { |k| @data[k].is_a?(Array) }
      key ? @data[key] : nil
    end

    def deep_dup_freeze(value)
      case value
      when Hash then value.transform_values { |v| deep_dup_freeze(v) }.freeze
      when Array then value.map { |v| deep_dup_freeze(v) }.freeze
      when String then value.dup.freeze
      else value.freeze
      end
    end
  end
end
