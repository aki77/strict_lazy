# frozen_string_literal: true

require "strict_lazy"
require "active_record"

require_relative "support/schema"
require_relative "support/models"
require_relative "support/query_counter"

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.include QueryCounter

  # Reset to the dev/test default before every example.
  config.before { StrictLazy.violation = :raise }

  # Clean data between examples; the in-memory schema persists.
  config.after do
    Comment.delete_all
    Post.delete_all
    Author.delete_all
  end
end
