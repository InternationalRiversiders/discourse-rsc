# frozen_string_literal: true
module DiscourseRsc
  # Read previously translated public catalog labels without spending AI quota.
  # This service never creates markets, approves requests or changes contract terms.
  module ForecastCatalogTranslation
    STORE = 'rsc_forecast_catalog_zh'

    def self.source(row)
      row = row.attributes if row.respond_to?(:attributes)
      row.stringify_keys.slice('external_id', 'question', 'event_title', 'outcomes')
    end

    def self.signature(row)
      Digest::SHA256.hexdigest(JSON.generate([1, SiteSetting.rsc_forecast_translation_model_id, source(row)]))
    end

    def self.cached(row, dictionary: nil)
      input = source(row)
      data = if dictionary
        dictionary[input['external_id']]
      else
        Rails.cache.fetch("rsc:forecast:label:#{input['external_id']}:#{signature(input)}", expires_in: 5.minutes) do
          PluginStore.get(STORE, input['external_id']) || {}
        end
      end
      data if data && data['signature'] == signature(input)
    end

    # Read existing translations only. Discovery and browsing do not call AI.
  end
end
