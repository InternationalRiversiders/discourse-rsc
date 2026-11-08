# frozen_string_literal: true
unless Rake::Task.task_defined?('rsc:build_arcade_embed')
namespace :rsc do
  desc 'Build the WebView UI from the same modules and styles as the forum'
  task :build_arcade_embed do
    require 'sass-embedded'
    root = File.expand_path('../..', __dir__)
    sass = File.join(Gem.loaded_specs.fetch('sass-embedded').full_gem_path, 'lib/sass/dart-sass/sass')
    sh 'python3', File.join(root, 'script/build-arcade-embed.py'), '--sass', sass
  end
end
end
# Both normal release paths rebuild the remote UI, so a future control change
# cannot silently update only the Ember page and leave the App on older controls.
Rake::Task.define_task('assets:precompile:build_plugins' => ['rsc:build_arcade_embed'])
Rake::Task.define_task('assets:precompile' => ['rsc:build_arcade_embed'])
