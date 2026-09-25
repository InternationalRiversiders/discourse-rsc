# frozen_string_literal: true
abort 'Disposable only' unless ENV['RIVER_DISPOSABLE']=='1'
require 'active_record'
ActiveRecord::Base.establish_connection(adapter:'postgresql',host:'127.0.0.1',username:'postgres',database:'river_forecast_migration_test')
c=ActiveRecord::Base.connection
abort 'Wrong database' unless c.current_database=='river_forecast_migration_test'
c.create_table(:users)
c.create_table(:discourse_rsc_journals)
require_relative '../db/migrate/20260925001000_create_rsc_forecast_market'
ActiveRecord::Migration.verbose=false
migration=CreateRscForecastMarket.new
migration.migrate(:up)
raise 'Missing check' unless c.check_constraints('discourse_rsc_forecast_positions').any? { |v| v.name=='rsc_forecast_position_bounds' }
raise 'Missing ledger FK' unless c.foreign_keys('discourse_rsc_forecast_trades').any? { |v| v.to_table=='discourse_rsc_journals' }
migration.migrate(:down)
raise 'Rollback incomplete' if c.table_exists?('discourse_rsc_forecast_markets')
migration.migrate(:up)
puts 'PASS: fresh migration, constraints, journal FK, rollback and reapply in disposable database'
