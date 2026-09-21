# frozen_string_literal: true
module DiscourseRsc
  class Catalog
    SUFFIXES = { "SSE" => "SS", "SHSE" => "SS", "SZSE" => "SZ", "TSE" => "T", "TYO" => "T", "EPA" => "PA", "PAR" => "PA", "AMS" => "AS", "AEX" => "AS", "BRU" => "BR", "LIS" => "LS", "BME" => "MC", "BIT" => "MI", "CPH" => "CO", "STO" => "ST", "HEL" => "HE", "OSL" => "OL", "VIE" => "VI", "WSE" => "WA", "ISE" => "IR", "XETRA" => "DE", "LSE" => "L", "SIX" => "SW", "TSX" => "TO", "TSECA" => "TO", "TSXV" => "V", "ASX" => "AX", "SGX" => "SI", "NSE" => "NS", "BSE" => "BO" }.freeze
    INDICES = { "SPX" => "^GSPC", "SP500" => "^GSPC", "NDX" => "^NDX", "IXIC" => "^IXIC", "DJI" => "^DJI", "HSI" => "^HSI", "N225" => "^N225", "FTSE" => "^FTSE", "DAX" => "^GDAXI", "VIX" => "^VIX", "RUT" => "^RUT", "CSI300" => "000300.SS", "FTSE100" => "^FTSE", "CAC40" => "^FCHI", "STOXX50" => "^STOXX50E", "ASX200" => "^AXJO", "KOSPI" => "^KS11", "STI" => "^STI", "TSX" => "^GSPTSE", "NIFTY50" => "^NSEI" }.freeze
    def self.provider(row)
      code = row.fetch("display_symbol", row.fetch("symbol").split(":").last).upcase
      exchange = row.fetch("exchange", row["symbol"].to_s.split(":").first).upcase
      if row["market_category"] == "crypto" || exchange == "CRYPTO"
        base = code.split(/[\/-]/).first
        return ["kraken", "#{base}USD"] if %w[XMR TRX].include?(base)
        return ["okx", "#{base == 'DRAM39945' ? 'DRAM' : base}-USDT-SWAP"] if %w[DRAM39945 SNDK].include?(base)
        return ["coinbase", "#{base}-USD"]
      end
      mapped = if exchange == "INDEX"
        INDICES.fetch(code, code)
      elsif exchange == "FX"
        pair = code.delete('/')
        "#{pair.length == 3 ? "#{pair}USD" : pair}=X"
      elsif exchange == "HKEX"
        "#{code.rjust(4, '0')}.HK"
      elsif exchange == "EURONEXT"
        "#{code}.#{row['trading_hours'].to_s.include?('Europe/Paris') ? 'PA' : 'AS'}"
      elsif SUFFIXES.key?(exchange)
        "#{code}.#{SUFFIXES[exchange]}"
      else
        code
      end
      ["yahoo", mapped]
    end
    def self.approve(actor:, symbol:, reason:, request_id:)
      Safety.ensure_writable!
      raise Error.new("admin_required", status: 403) unless Access.admin?(actor)
      raise Error.new("provider_disabled", status: 503) unless SiteSetting.rsc_market_data_enabled
      raise Error.new("reason_required") unless reason.is_a?(String) && reason.strip.length.between?(1, 500)
      requested_code = MarketData.symbol(symbol)
      code = if requested_code.start_with?('CRYPTO:'); requested_code.split(':', 2).last.tr('/', '-')
        elsif requested_code.include?(':'); provider({'symbol'=>requested_code}).last
        else requested_code; end
      code = MarketData.symbol(code)
      code = "#{code.delete_suffix('=X')}USD=X" if /\A[A-Z]{3}=X\z/.match?(code)
      find_existing = -> { Instrument.find_by(symbol: requested_code) || Instrument.find_by(symbol: code) || Instrument.find_by(provider_symbol: code) }
      # Remote I/O must never hold the global trade lock or a money transaction.
      candidate = external_candidate(code) unless find_existing.call
      Commands.run(user_id: actor.id, action: 'market_approve', request_id: request_id, input: [requested_code, reason.strip]) do
        Commands.lock('rsc-exchange')
        item = find_existing.call
        existed = !!item
        if item
          raise Error.new('instrument_inactive') unless item.active?
        else
          item = Instrument.create!(candidate)
        end
        MarketRequest.where(symbol: [requested_code, code, item.symbol], status: 'pending').update_all(status: 'approved', updated_at: Time.current)
        Audit.create!(actor_user_id: actor.id, action: 'market_approve', details: { symbol: code, instrument_id: item.id, reason: reason.strip }, created_at: Time.current)
        { instrument_id: item.id, existing: existed }
      end
    end

    def self.supported_external?(code, type)
      return false unless %w[EQUITY ETF MUTUALFUND INDEX CURRENCY CRYPTOCURRENCY].include?(type)
      return INDICES.value?(code) if type == 'INDEX'
      return /\A(?!USD)(?:[A-Z]{3}USD|[A-Z]{3})=X\z/.match?(code) if type == 'CURRENCY'
      !code.start_with?('^') && !code.match?(/[=:]/)
    end

    def self.external_candidate(code)
      meta = MarketData.yahoo_chart(code).fetch('meta')
      raise Error.new('provider_no_data') unless meta['symbol'].to_s.upcase == code
      raise Error.new('invalid_symbol') unless supported_external?(code, meta['instrumentType'])
      category = if meta['instrumentType']=='INDEX'; 'indices'
        elsif code.end_with?('=X'); 'forex'
        elsif code.end_with?('.HK'); 'hk'
        elsif code.end_with?('.SS', '.SZ'); 'cn'
        elsif code.end_with?('.T'); 'jp'
        elsif code.end_with?('.TO', '.V'); 'ca'
        elsif code.end_with?('.AX'); 'au'
        elsif code.end_with?('.SI'); 'sg'
        elsif code.end_with?('.NS', '.BO'); 'in'
        elsif code.match?(/\.(L|PA|AS|BR|LS|MC|MI|CO|ST|HE|OL|VI|WA|IR|DE|SW)\z/); 'eu'
        elsif meta['instrumentType']=='CRYPTOCURRENCY'; 'crypto'
        else 'us'; end
      provider, provider_code = category == 'crypto' ? Catalog.provider({'symbol'=>code,'display_symbol'=>code,'market_category'=>'crypto'}) : ['yahoo',code]
      name = meta['longName'].presence || meta['shortName'].presence || code
      metal = %w[ETF MUTUALFUND].include?(meta['instrumentType']) && (%w[BAR GLD GLDM IAU OUNZ PALL PPLT SGOL SIVR SLV].include?(code.split('.').first) || (!name.upcase.include?('MINER') && name.upcase.match?(/GOLD TRUST|GOLD SHARES|SILVER TRUST|SILVER SHARES|PHYSICAL (GOLD|SILVER|PLATINUM|PALLADIUM)/)))
      category = 'metals' if metal
      raise Error.new('market_opening_disabled') if %w[ca in au].include?(category)
      unit = Amount.parse(category == 'crypto' ? '0.000001' : '0.01')
      fee = {'crypto'=>20,'cn'=>13,'us'=>5,'indices'=>5,'forex'=>5,'metals'=>5}.fetch(category,10)
      attributes = {symbol:code,name:name,
        provider:provider,provider_symbol:provider_code,category:category,currency:meta.fetch('currency','USD'),
        asset_type:metal ? 'metal' : {'EQUITY'=>'stock','ETF'=>'etf','MUTUALFUND'=>'fund','INDEX'=>'index','CURRENCY'=>'forex','CRYPTOCURRENCY'=>'crypto'}.fetch(meta['instrumentType'],'stock'),
        fee_bps:fee,minimum_units:unit,step_units:unit}
      quote = MarketData.fetch_quote(Instrument.new(attributes))
      attributes.merge(quote:quote,history:[{at:quote['source_time'],price:quote['price']}],synced_at:Time.current)
    end

    def self.seed
      path = File.expand_path("../../../config/market-symbols.txt", __dir__)
      count = 0
      File.foreach(path) do |line|
        next if line.strip.empty? || line.start_with?("#")
        symbol, name, currency, category, asset, fee = line.strip.split("|")
        next if Instrument.exists?(symbol: symbol)
        provider, code = provider({ "symbol" => symbol, "name" => name, "market_category" => category })
        Instrument.create!(symbol: symbol, name: name, asset_type: asset.to_s, currency: currency, category: category, provider: provider, provider_symbol: code, fee_bps: fee.to_i,
                           minimum_units: Amount.parse(category == "crypto" ? "0.000001" : "0.01"), step_units: Amount.parse(category == "crypto" ? "0.000001" : "0.01"))
        count += 1
      end
      count
    end
  end
end
