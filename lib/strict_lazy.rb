# frozen_string_literal: true

require "active_support"
require "active_support/concern"
require "active_support/core_ext/class/attribute"

require_relative "strict_lazy/version"
require_relative "strict_lazy/errors"
require_relative "strict_lazy/loader"
require_relative "strict_lazy/batch"
require_relative "strict_lazy/facade"

# strict_lazy applies the spirit of Rails' +strict_loading+ to computed values.
# Include it in a model, declare values with +lazy_load+, prepare them in the
# controller with +StrictLazy.preload+, and read them via +record.lazy.x+.
# Reading without a preceding preload raises in development/test.
module StrictLazy
  extend ActiveSupport::Concern

  # How to react when a lazy value is read without a preceding preload.
  # :raise (dev/test default), :log, or :ignore. Set via StrictLazy.violation=.
  mattr_accessor :violation, default: :raise

  included do
    # Inherited by STI subclasses; merged (not mutated) on each declaration.
    class_attribute :lazy_loaders, instance_writer: false, default: {}
  end

  class_methods do
    # Declare a lazy-loaded value.
    #
    #   lazy_load :comments_count, default: 0 do |posts, loader|
    #     ...
    #   end
    #
    #   lazy_load :avatar, from: :resolve_avatar, sync: true
    #
    # Exactly one of +from:+ or a block is required (xor). +sync: true+ resolves
    # eagerly at preload time; otherwise resolution is deferred to first read.
    # +default+ is written for records the resolver does not fulfill; pass a
    # callable for per-record (e.g. mutable) defaults.
    def lazy_load(reader, from: nil, sync: false, default: nil, &block)
      raise ArgumentError, "lazy_load #{reader.inspect}: pass either `from:` or a block, not both" if from && block
      raise ArgumentError, "lazy_load #{reader.inspect}: pass either `from:` or a block" unless from || block
      if from && !respond_to?(from)
        raise ArgumentError, "lazy_load #{reader.inspect}: `from: #{from.inspect}` is not defined on #{name}. " \
                             "Define the class method before the lazy_load declaration."
      end

      loader = Loader.new(reader: reader, sync: sync, default: default, from: from, block: block)
      self.lazy_loaders = lazy_loaders.merge(reader => loader)
    end
  end

  # The +.lazy+ namespace facade (memoized per record).
  def lazy
    @_lazy_facade ||= Facade.new(self)
  end

  # Prepare lazy values for a group of records. With no readers, prepares every
  # declared loader. +sync: true+ loaders resolve immediately; others on first read.
  def self.preload(records, *readers)
    records = Array(records)
    return records if records.empty?

    model = records.first.class
    loaders_for(model, readers).each do |loader|
      batch = Batch.new(model, records, loader)
      records.each { |record| record.instance_variable_set(loader.batch_ivar, batch) }
      batch.resolve! if loader.sync?
    end

    records
  end

  def self.loaders_for(model, readers)
    all = model.lazy_loaders
    readers.empty? ? all.values : readers.map { |r| all.fetch(r) }
  end
  private_class_method :loaders_for
end

require_relative "strict_lazy/railtie" if defined?(Rails::Railtie)
