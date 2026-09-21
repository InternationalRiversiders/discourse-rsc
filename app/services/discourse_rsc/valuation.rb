# frozen_string_literal: true
module DiscourseRsc
  # Display-only marks. Never use these values in Exchange, Ledger or Risk.
  # Like the old leaderboard, use the last quote even on a closed market;
  # without a valid quote use entry cost, and disclose the valuation basis.
  module Valuation
    def self.mark(instrument)
      quote = instrument.quote
      price = Amount.positive(quote["price"])
      current = begin
        Exchange.price!(instrument)
        true
      rescue Error
        false
      end
      { price: price, basis: current ? "current" : "last_quote", at: quote["source_time"] }
    rescue Error, ArgumentError, TypeError
      { price: nil, basis: "cost", at: nil }
    end

    def self.position(position, mark = nil)
      mark ||= self.mark(position.instrument)
      price = mark[:price] || position.average_units.to_i
      # Match the legacy integer rounding: round each notional before subtracting.
      cost = position.quantity_units.to_i * position.average_units.to_i / Amount::UNIT
      value = position.quantity_units.to_i * price / Amount::UNIT
      pnl = position.side == "short" ? cost - value : value - cost
      { pnl: [pnl, -position.margin_units.to_i].max, basis: mark[:basis], at: mark[:at], price: Amount.format(price) }
    end
  end
end
