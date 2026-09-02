# frozen_string_literal: true

require "spec_helper"

RSpec.describe PearlPay::ListObject do
  def offset_page(page:, total_pages:, ids:)
    JSON.generate(
      object: "list",
      data: ids.map { |id| { id: id, object: "payment" } },
      meta: { page: page, per_page: 2, total: 5, total_pages: total_pages,
              from: "2026-01-01", to: "2026-04-14" }
    )
  end

  def cursor_page(ids:, has_more:, next_cursor: nil)
    meta = { limit: 2, has_more: has_more }
    meta[:next_starting_after] = next_cursor if next_cursor
    JSON.generate(object: "list",
                  data: ids.map { |id| { id: id, object: "payment_link" } }, meta: meta)
  end

  describe "offset pagination (payments, disbursements)" do
    it "exposes meta and derives has_more? from page < total_pages" do
      stub_request(:get, "#{SpecSupport::BASE}/v1/payments")
        .to_return(status: 200, body: offset_page(page: 1, total_pages: 3, ids: %w[pay_1 pay_2]),
                   headers: json_headers)
      list = build_client.v1.payments.list
      expect(list.pagination).to eq(:offset)
      expect(list.meta.page).to eq(1)
      expect(list.meta.total).to eq(5)
      expect(list.has_more?).to be(true)
      expect(list.map(&:id)).to eq(%w[pay_1 pay_2])
    end

    it "auto_paging_each walks every page through the full pipeline, keeping filters" do
      stub_request(:get, "#{SpecSupport::BASE}/v1/payments")
        .with(query: { "status" => "succeeded" })
        .to_return(status: 200, body: offset_page(page: 1, total_pages: 3, ids: %w[pay_1 pay_2]),
                   headers: json_headers)
      stub_request(:get, "#{SpecSupport::BASE}/v1/payments")
        .with(query: { "status" => "succeeded", "page" => "2" })
        .to_return(status: 200, body: offset_page(page: 2, total_pages: 3, ids: %w[pay_3 pay_4]),
                   headers: json_headers)
      stub_request(:get, "#{SpecSupport::BASE}/v1/payments")
        .with(query: { "status" => "succeeded", "page" => "3" })
        .to_return(status: 200, body: offset_page(page: 3, total_pages: 3, ids: %w[pay_5]),
                   headers: json_headers)

      ids = build_client.v1.payments.list(status: "succeeded").auto_paging_each.map(&:id)
      expect(ids).to eq(%w[pay_1 pay_2 pay_3 pay_4 pay_5])
    end
  end

  describe "cursor pagination (payment_links)" do
    it "exposes next_cursor from meta.next_starting_after" do
      stub_request(:get, "#{SpecSupport::BASE}/v1/payment_links")
        .to_return(status: 200,
                   body: cursor_page(ids: %w[plink_1 plink_2], has_more: true,
                                     next_cursor: "plink_2"),
                   headers: json_headers)
      list = build_client.v1.payment_links.list
      expect(list.pagination).to eq(:cursor)
      expect(list.has_more?).to be(true)
      expect(list.next_cursor).to eq("plink_2")
    end

    it "auto_paging_each follows starting_after until has_more is false" do
      stub_request(:get, "#{SpecSupport::BASE}/v1/payment_links")
        .to_return(status: 200,
                   body: cursor_page(ids: %w[plink_1 plink_2], has_more: true,
                                     next_cursor: "plink_2"),
                   headers: json_headers)
      stub_request(:get, "#{SpecSupport::BASE}/v1/payment_links")
        .with(query: { "starting_after" => "plink_2" })
        .to_return(status: 200, body: cursor_page(ids: %w[plink_3], has_more: false),
                   headers: json_headers)

      ids = build_client.v1.payment_links.list.auto_paging_each.map(&:id)
      expect(ids).to eq(%w[plink_1 plink_2 plink_3])
      # next_starting_after is present only when has_more; the last page ends cleanly.
    end
  end

  describe "unpaginated lists (webhook_endpoints, rails, partners)" do
    it "webhook_endpoints.list: auto_paging_each is plain each" do
      stub_request(:get, "#{SpecSupport::BASE}/v1/webhook_endpoints")
        .to_return(status: 200,
                   body: JSON.generate(object: "list",
                                       data: [{ id: "we_1", object: "webhook_endpoint" }]),
                   headers: json_headers)
      list = build_client.v1.webhook_endpoints.list
      expect(list.pagination).to eq(:none)
      expect(list.has_more?).to be(false)
      expect(list.auto_paging_each.map(&:id)).to eq(%w[we_1])
      expect(WebMock).to have_requested(:get, "#{SpecSupport::BASE}/v1/webhook_endpoints").once
    end

    it "finds the array under rails/partners keys" do
      stub_request(:get, "#{SpecSupport::BASE}/v1/disbursements/rails")
        .to_return(status: 200,
                   body: JSON.generate(object: "list",
                                       rails: [{ code: "instapay", max_amount: "50000.00" }]),
                   headers: json_headers)
      stub_request(:get, "#{SpecSupport::BASE}/v1/disbursements/rails/instapay/partners")
        .to_return(status: 200,
                   body: JSON.generate(object: "list", rail: "instapay",
                                       partners: [{ code: "BDO", partner_type: "bank" }]),
                   headers: json_headers)

      client = build_client
      rails = client.v1.disbursement_rails.list
      expect(rails.map(&:code)).to eq(%w[instapay])
      expect(rails.first.max_amount).to eq("50000.00") # decimal string passes through

      partners = client.v1.disbursement_rails.partners("instapay")
      expect(partners.map(&:code)).to eq(%w[BDO])
      expect(partners["rail"]).to eq("instapay")
    end
  end
end
