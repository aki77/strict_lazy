# frozen_string_literal: true

module StrictLazy
  # Drives +StrictLazy.preload+: interprets the Rails-style spec, prepares each
  # level's readers (grouped by STI base class), and traverses associations to
  # descend into nested records. One instance handles a single level of records;
  # nested levels are handled by recursing into fresh instances.
  class Preloader
    # Prepare +spec+ on +records+. See +StrictLazy.preload+ for the spec grammar.
    def self.call(records, spec)
      records = Array(records)
      return records if records.empty?

      new(records).call(spec)
      records
    end

    def initialize(records)
      @records = records
    end

    def call(spec)
      hashes, readers = spec.partition { |element| element.is_a?(Hash) }

      preload_here(readers) if prepare_this_level?(spec, readers)

      hashes.flat_map(&:to_a).each do |association, sub_spec|
        children = traverse(association)
        # Array.wrap (not Kernel#Array) so a Hash sub-spec stays a single element
        # ([hash]) instead of being split into key/value pairs.
        self.class.call(children, Array.wrap(sub_spec))
      end
    end

    private

    # An empty spec means "all loaders" (the historical no-args behavior); a
    # Hash-only spec prepares nothing here and only descends into children.
    def prepare_this_level?(spec, readers)
      spec.empty? || readers.any?
    end

    # Prepare +readers+ on this level, grouping by STI base class so each loader's
    # resolver runs once per declaring class with the correct dispatch receiver.
    def preload_here(readers)
      @records.group_by { |record| base_model_for(record) }.each do |model, group|
        loaders_for(model, readers).each do |loader|
          batch = Batch.new(model, group, loader)
          group.each { |record| record.instance_variable_set(loader.batch_ivar, batch) }
          batch.resolve! if loader.sync?
        end
      end
    end

    # The STI base class (the class the loaders are declared on) for a record,
    # falling back to its class when +base_class+ is unavailable.
    def base_model_for(record)
      klass = record.class
      klass.respond_to?(:base_class) ? klass.base_class : klass
    end

    # Follow an association across every record and return the flattened
    # children. belongs_to/has_one (singular or nil) and has_many are unified via
    # Array.wrap. When the records are ActiveRecord-backed, the association is
    # batch-preloaded first to avoid N+1; otherwise we rely on the caller having
    # already preloaded it.
    def traverse(association)
      # Reflection lives on the base class and is uniform across the group, so
      # inspecting the first record is enough here (unlike preload_here, which
      # must group every record by class to dispatch resolvers correctly).
      klass = base_model_for(@records.first)
      unless klass.respond_to?(:reflect_on_association) && klass.reflect_on_association(association)
        raise ArgumentError, "StrictLazy.preload: #{klass}##{association} is not an association"
      end

      preload_association(association)
      # Array.wrap turns nil/singular/has_many into a flat element list; an absent
      # singular association yields [], so no compact is needed.
      @records.flat_map { |record| Array.wrap(record.public_send(association)) }
    end

    # Batch-preload an ActiveRecord association to avoid N+1. No-op (degrading to
    # the caller's own preloading) when the Preloader is unavailable.
    def preload_association(association)
      return unless defined?(ActiveRecord::Associations::Preloader)

      ActiveRecord::Associations::Preloader.new(records: @records, associations: association).call
    end

    def loaders_for(model, readers)
      all = model.lazy_loaders
      readers.empty? ? all.values : readers.map { |r| all.fetch(r) }
    end
  end
end
