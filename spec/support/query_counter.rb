# frozen_string_literal: true

# Counts real SQL queries (excluding SCHEMA/TRANSACTION housekeeping) via the
# +sql.active_record+ notification, so tests can assert "0 queries until read,
# 1 query on first read".
module QueryCounter
  IGNORED = %w[SCHEMA TRANSACTION].freeze

  def count_queries
    count = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
      payload = args.last
      name = payload[:name]
      count += 1 unless IGNORED.include?(name) || payload[:sql] =~ /^\s*(BEGIN|COMMIT|ROLLBACK)/i
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end
