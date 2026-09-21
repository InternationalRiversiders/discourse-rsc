# frozen_string_literal: true

module DiscourseRsc
  class Engine < ::Rails::Engine
    engine_name PLUGIN_NAME
    isolate_namespace DiscourseRsc
  end
end
