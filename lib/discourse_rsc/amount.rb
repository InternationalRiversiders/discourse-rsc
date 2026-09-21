# frozen_string_literal: true

module DiscourseRsc
  # Preserve the legacy 18 decimal places. Never pass money through Float.
  module Amount
    SCALE = 18
    UNIT = 10**SCALE
    MAX_UNITS = 10**78 - 1

    def self.parse(value, decimals: SCALE)
      unless value.is_a?(String) && value.bytesize <= 80 &&
               /\A(?:0|[1-9][0-9]*)(?:\.[0-9]{1,#{decimals}})?\z/.match?(value)
        raise Error.new("invalid_amount")
      end
      whole, fraction = value.split(".", 2)
      units = whole.to_i * UNIT + (fraction || "").ljust(SCALE, "0").to_i
      raise Error.new("invalid_amount") if units > MAX_UNITS
      units
    end

    def self.positive(value, decimals: SCALE)
      units = parse(value, decimals: decimals)
      raise Error.new("invalid_amount") unless units.positive?
      units
    end

    def self.display(units, decimals: 4)
      integer = units.to_i
      factor = 10**(SCALE - decimals)
      truncated = integer.abs / factor * factor
      return "<#{format(factor)}" if integer.positive? && truncated.zero?
      return ">-#{format(factor)}" if integer.negative? && truncated.zero?
      format(integer.negative? ? -truncated : truncated)
    end

    def self.format(units)
      integer = units.to_i
      raise Error.new("invalid_amount") unless units == integer
      whole, fraction = integer.abs.divmod(UNIT)
      suffix = fraction.zero? ? "" : ".#{fraction.to_s.rjust(SCALE, '0').sub(/0+\z/, '')}"
      "#{integer.negative? ? '-' : ''}#{whole}#{suffix}"
    end
  end
end
