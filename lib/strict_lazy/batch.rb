# frozen_string_literal: true

module StrictLazy
  # A single +StrictLazy.preload+ × single loader unit of work, shared by every
  # record in the group via +@_batch_<reader>+. The resolver runs exactly once;
  # values are written straight onto each record's +@_lazy_<reader>+ ivar, so the
  # batch keeps no intermediate Hash and never relies on record hash-equality
  # (unsaved records work fine).
  class Batch
    def initialize(model, records, loader)
      @model = model
      @records = records
      @loader = loader
      @resolved = false
    end

    # Resolve the value for one record, resolving the whole group on first touch.
    def value_for(record)
      resolve! unless @resolved
      record.instance_variable_get(@loader.value_ivar)
    end

    # Run the resolver once and write defaults for any record it skipped.
    def resolve!
      return if @resolved

      @resolved = true
      fulfilled = {}.compare_by_identity
      fulfill = lambda do |record, value|
        fulfilled[record] = true
        record.instance_variable_set(@loader.value_ivar, value)
      end

      @loader.resolve(@model, @records, fulfill)

      @records.each do |record|
        next if fulfilled.key?(record)

        record.instance_variable_set(@loader.value_ivar, @loader.default_for(record))
      end
    end
  end
end
