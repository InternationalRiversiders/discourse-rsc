# frozen_string_literal: true
module DiscourseRsc
  module Safety
    def self.read_only?
      SiteSetting.rsc_read_only
    end

    def self.ensure_writable!
      raise Error.new("read_only", status: 503) if read_only?
    end

    # The immutable ledger must retain its original owner. Discourse's generic
    # merge/delete machinery does not know about RSC escrow or historical claims.
    # Anonymization keeps the user ID and remains available.
    def self.ensure_user_retained!(user)
      return unless user && Account.table_exists?
      involved = Account.exists?(user_id: user.id) || Position.exists?(user_id: user.id) ||
        Prediction.exists?(user_id: user.id) || Packet.exists?(user_id: user.id) ||
        LegacyRecord.where("data ->> 'discourse_user_id' = ?", user.id.to_s).exists?
      raise Discourse::InvalidParameters.new(I18n.t("discourse_rsc.errors.user_has_history")) if involved
    end

    module MergeGuard
      def merge!
        DiscourseRsc::Safety.ensure_user_retained!(@source_user)
        super
      end
    end

    module DeleteGuard
      def destroy(user, opts = {})
        DiscourseRsc::Safety.ensure_user_retained!(user)
        super
      end
    end
  end
end
