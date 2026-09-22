# frozen_string_literal: true
module DiscourseRsc
  module UserIdentity
    def self.serialize(user_or_id)
      return nil unless user_or_id
      user = user_or_id.is_a?(User) ? user_or_id : User.find_by(id: user_or_id)
      user && { id: user.id, username: user.username, avatar_template: user.avatar_template }
    end
  end
end
