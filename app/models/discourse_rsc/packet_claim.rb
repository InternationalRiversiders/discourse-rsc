# frozen_string_literal: true
module DiscourseRsc
  class PacketClaim < ActiveRecord::Base
    self.table_name = "discourse_rsc_packet_claims"
    attribute :units, :decimal, precision: 78
  end
end
