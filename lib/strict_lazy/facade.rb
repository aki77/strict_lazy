# frozen_string_literal: true

module StrictLazy
  # The +.lazy+ namespace. Reading +record.lazy.x+ resolves a declared lazy
  # value without ever growing a bare +x+ method on the record itself.
  #
  # Read order:
  #   1. +@_lazy_<reader>+ already set  -> return it (resolved / eager / group-resolved)
  #   2. +@_batch_<reader>+ present     -> resolve the whole group once, return it
  #   3. no batch and violation :raise  -> UnloadedError (no wasted query)
  #   4. no batch and non-strict        -> degraded single-record resolve (fallback)
  class Facade
    def initialize(record)
      @record = record
    end

    def respond_to_missing?(name, include_private = false)
      loaders.key?(name) || super
    end

    def method_missing(name, *args)
      loader = loaders[name]
      return super unless loader

      return @record.instance_variable_get(loader.value_ivar) if @record.instance_variable_defined?(loader.value_ivar)

      batch = @record.instance_variable_get(loader.batch_ivar)
      return batch.value_for(@record) if batch

      unloaded(loader)
    end

    private

    def loaders
      @record.class.lazy_loaders
    end

    # No preceding preload reached this record.
    def unloaded(loader)
      case StrictLazy.violation
      when :raise
        raise UnloadedError, "#{@record.class}##{loader.reader} was read without a preceding " \
                             "StrictLazy.preload. Add it to the controller, or set " \
                             "StrictLazy.violation to :log/:ignore."
      when :log
        logger&.warn("[StrictLazy] #{@record.class}##{loader.reader} read without preload (degraded to N+1)")
      end

      # :log and :ignore fall through to a degraded single-record resolve.
      Batch.new(@record.class, [@record], loader).value_for(@record)
    end

    def logger
      defined?(Rails) && Rails.respond_to?(:logger) ? Rails.logger : nil
    end
  end
end
