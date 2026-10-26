# frozen_string_literal: true
module DiscourseRsc
  module ForexCatalog
    # One currency unit priced in USD/RSC, not a separate USD/base short product.
    CURRENCIES = {
      'EUR'=>['欧元', 'Euro', '欧盟 欧元区 欧洲'],
      'GBP'=>['英镑', 'British Pound', '英国 Britain UK'],
      'JPY'=>['日元', 'Japanese Yen', '日本 Japan'],
      'CHF'=>['瑞郎', 'Swiss Franc', '瑞士法郎 瑞士 Switzerland'],
      'CAD'=>['加元', 'Canadian Dollar', '加拿大元 加拿大 Canada'],
      'AUD'=>['澳元', 'Australian Dollar', '澳大利亚 澳币 Australia'],
      'NZD'=>['新西兰元', 'New Zealand Dollar', '纽元 纽币 New Zealand'],
      'CNY'=>['人民币', 'Chinese Yuan', '中国 China RMB'],
      'HKD'=>['港元', 'Hong Kong Dollar', '香港 港币 Hong Kong'],
      'SGD'=>['新加坡元', 'Singapore Dollar', '新加坡 新元 新币 Singapore'],
      'INR'=>['印度卢比', 'Indian Rupee', '印度 India'],
      'KRW'=>['韩元', 'South Korean Won', '韩国 韩币 South Korea'],
      'BRL'=>['巴西雷亚尔', 'Brazilian Real', '巴西 雷亚尔 雷亚尔币 Brazil'],
      'MXN'=>['墨西哥比索', 'Mexican Peso', '墨西哥 Mexico'],
      'ZAR'=>['南非兰特', 'South African Rand', '南非 South Africa'],
      'TRY'=>['土耳其里拉', 'Turkish Lira', '土耳其 Turkey Türkiye'],
      'SEK'=>['瑞典克朗', 'Swedish Krona', '瑞典 Sweden'],
      'NOK'=>['挪威克朗', 'Norwegian Krone', '挪威 Norway'],
      'DKK'=>['丹麦克朗', 'Danish Krone', '丹麦 Denmark'],
      'PLN'=>['波兰兹罗提', 'Polish Zloty', '波兰 Poland'],
      'CZK'=>['捷克克朗', 'Czech Koruna', '捷克 Czechia'],
      'HUF'=>['匈牙利福林', 'Hungarian Forint', '匈牙利 Hungary'],
      'THB'=>['泰铢', 'Thai Baht', '泰国 Thailand'],
      'IDR'=>['印尼盾', 'Indonesian Rupiah', '印尼 印度尼西亚 卢比 印尼卢比 Indonesia'],
      'MYR'=>['马来西亚林吉特', 'Malaysian Ringgit', '马来西亚 马币 令吉 Malaysia'],
      'PHP'=>['菲律宾比索', 'Philippine Peso', '菲律宾 Philippines'],
      'TWD'=>['新台币', 'Taiwan Dollar', '台币 台湾 Taiwan']
    }.transform_values(&:freeze).freeze

    def self.base(instrument)
      return unless instrument.category == 'forex'
      MarketData.forex_base(instrument) || instrument.symbol.to_s[/\AFX:([A-Z]{3})\z/, 1]
    end

    def self.name(instrument)
      CURRENCIES.dig(base(instrument), 0) || instrument.name
    end

    def self.search_text(code)
      return '' unless code
      ([code, "FX:#{code}", "#{code}=X", "#{code}USD=X", "#{code}/USD", "USD/#{code}", "USD#{code}"] + Array(CURRENCIES[code])).join(' ')
    end

    def self.search(query)
      needle = query.strip.downcase
      CURRENCIES.filter_map do |code, (name, _english, _aliases)|
        next unless search_text(code).downcase.include?(needle)
        { symbol: "#{code}=X", name: name, exchange: 'FX', type: 'CURRENCY' }
      end
    end
  end
end
