# frozen_string_literal: true

module StrictLazy
  # Sets the environment-appropriate +violation+ default: +:raise+ in
  # development/test (catch missing preloads), +:ignore+ in production
  # (degrade to N+1 rather than crash). Override with
  # +config.strict_lazy.violation+. No middleware: values and batches live on
  # the records and are GC'd with the request.
  class Railtie < Rails::Railtie
    config.strict_lazy = ActiveSupport::OrderedOptions.new

    initializer "strict_lazy.set_violation" do |app|
      default = Rails.env.production? ? :ignore : :raise
      StrictLazy.violation = app.config.strict_lazy.violation || default
    end
  end
end
