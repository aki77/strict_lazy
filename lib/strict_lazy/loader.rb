# frozen_string_literal: true

module StrictLazy
  # Immutable definition produced by a +lazy_load+ declaration.
  #
  # It holds the reader name, the resolver (a +from:+ method symbol or a block),
  # whether resolution is eager (+sync:+), and the +default+ used for records the
  # resolver does not fulfill.
  #
  # Resolution always goes through +#resolve+, which is handed the model class so
  # a +from:+ symbol can be dispatched as a class method. A block resolver is
  # +instance_exec+'d on the model class for the same lookup semantics.
  class Loader
    # Internal ivar names are reserved per reader: +@_lazy_<reader>+ holds the
    # resolved value, +@_batch_<reader>+ holds the shared Batch reference.
    attr_reader :reader, :sync, :default

    def initialize(reader:, sync:, default:, from: nil, block: nil)
      @reader = reader
      @sync = sync
      @default = default
      @from = from
      @block = block
      @value_ivar = :"@_lazy_#{reader}"
      @batch_ivar = :"@_batch_#{reader}"
    end

    def sync? = @sync

    attr_reader :value_ivar, :batch_ivar

    # Invoke the resolver once over +records+. +loader+ is the
    # +loader.call(record, value)+ callable supplied by the Batch.
    def resolve(model, records, loader)
      if @from
        model.public_send(@from, records, loader)
      else
        model.instance_exec(records, loader, &@block)
      end
    end

    # Compute the default for a record the resolver did not fulfill.
    # A callable default acts as a per-record factory so mutable values
    # (+[]+, +{}+) are never shared; arity 1 receives the record.
    def default_for(record)
      return @default unless @default.respond_to?(:call)

      @default.arity.zero? ? @default.call : @default.call(record)
    end
  end
end
