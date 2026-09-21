# frozen_string_literal: true

module DiscourseRsc
  class WalletController < ::ApplicationController
    requires_plugin DiscourseRsc::PLUGIN_NAME
    before_action :ensure_logged_in
    before_action :ensure_writable_request
    before_action :ensure_rsc_member, except: [:issue]

    rescue_from DiscourseRsc::Error do |error|
      render json: { errors: [I18n.t("discourse_rsc.errors.#{error.code}", default: error.code)],
                     error_code: error.code }, status: error.status
    end

    def show
      account = Account.wallet_snapshot(current_user.id)
      render_json_dump(balance: account.balance, status: account.status, status_reason: account.status_reason, read_only: Safety.read_only?)
    end

    def history
      data=WalletHistory.page(current_user, category: params.fetch(:category,"all"), cursor: params[:cursor])
      if params[:journal_id].present?
        entry=Entry.includes(:journal).find_by!(account_id:Account.wallet_snapshot(current_user.id).id,journal_id:positive_id(:journal_id))
        data[:focused_entry]=WalletHistory.native_entry(entry,current_user)
      end
      render_json_dump(data)
    end

    def entries
      account = Account.wallet_snapshot(current_user.id)
      records = Entry.where(account_id: account.id).includes(:journal).order(id: :desc).limit(50)
      records = records.where("id < ?", positive_id(:before)) if params[:before].present?
      render_json_dump(entries: records.map { |entry|
        { id: entry.id, journal_id: entry.journal_id, operation: entry.journal.operation,
          amount: Amount.format(entry.units), balance_after: Amount.format(entry.balance_after_units),
          created_at: entry.created_at }
      })
    end

    def transfer
      recipient = params[:recipient_username].present? ? User.find_by!(username_lower: params[:recipient_username].to_s.downcase) : User.find(positive_id(:recipient_user_id))
      result = Wallet.transfer(actor: current_user, recipient: recipient,
                               amount: params.require(:amount), request_id: params.require(:request_id))
      render_result(result)
    end

    def tip
      post = Post.find(positive_id(:post_id))
      guardian.ensure_can_see!(post)
      result = Wallet.transfer(actor: current_user, recipient: post.user, post: post,
                               amount: params.require(:amount), request_id: params.require(:request_id))
      render_result(result)
    end

    def issue
      raise Error.new("admin_required", status: 403) unless Access.admin?(current_user)
      result = Wallet.issue(actor: current_user, recipient: User.find(positive_id(:recipient_user_id)),
                            amount: params.require(:amount), reason: params.require(:reason),
                            request_id: params.require(:request_id))
      render_result(result)
    end

    private

    def ensure_writable_request
      Safety.ensure_writable! unless request.get? || request.head?
    end

    def ensure_rsc_member
      Access.ensure_member!(current_user)
    end

    def positive_id(name)
      value = params.require(name).to_s
      raise Discourse::InvalidParameters.new(name) unless /\A[1-9][0-9]{0,18}\z/.match?(value)
      value.to_i
    end

    def render_result(result)
      render_json_dump({ journal_id: result.journal.id, replayed: result.replayed },
                       status: result.replayed ? 200 : 201)
    end
  end
end
