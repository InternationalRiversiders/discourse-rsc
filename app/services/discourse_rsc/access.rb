# frozen_string_literal: true

module DiscourseRsc
  module Access
    def self.ensure_member!(user)
      raise Error.new("login_required", status: 401) unless user
      unless member?(user)
        raise Error.new("membership_required", status: 403)
      end
    end

    def self.member?(user)
      user && user.active? && !user.suspended? && user.groups.where(id: SiteSetting.rsc_allowed_groups.to_s.split("|").map(&:to_i)).exists?
    end

    def self.admin?(user)
      user && user.active? && !user.suspended? &&
        (user.admin? || user.groups.where(id: SiteSetting.rsc_admin_groups.to_s.split("|").map(&:to_i)).exists?)
    end
  end
end
