# Run with: bundle exec rails runner plugins/discourse-rsc/script/import_legacy.rb export.json
# Default: full transactional rehearsal followed by rollback.
path = ARGV.fetch(0)
review = ENV['RSC_IMPORT_IDENTITY_REVIEW'].present? ? JSON.parse(File.read(ENV.fetch('RSC_IMPORT_IDENTITY_REVIEW'))) : {}
result = DiscourseRsc::LegacyImport.run(path, apply: ENV["RSC_IMPORT_APPLY"] == "1", expected_sha256: ENV["RSC_IMPORT_SHA256"], identity_review: review)
puts JSON.pretty_generate(result)
