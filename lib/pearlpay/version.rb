# frozen_string_literal: true

module PearlPay
  VERSION = "0.3.2"

  # Pinned API version sent on every request as X-Api-Version. The server
  # currently ignores it; no negotiation logic exists by design.
  API_VERSION = "2026-04-14"
end
