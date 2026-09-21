# frozen_string_literal: true
module DiscourseRsc
  class Packet < ActiveRecord::Base
    self.table_name = "discourse_rsc_packets"
    attribute :total_units, :decimal, precision: 78
    attribute :minimum_units, :decimal, precision: 78
    attribute :maximum_units, :decimal, precision: 78
    has_many :claims, class_name: "DiscourseRsc::PacketClaim", foreign_key: :packet_id
  end
end
