# frozen_string_literal: true

require "active_support"
require "active_support/concern"
require "active_support/core_ext/class/attribute"
require "active_support/core_ext/module/attribute_accessors_per_thread"
require "active_support/core_ext/array/wrap"

require_relative "strict_lazy/version"
require_relative "strict_lazy/errors"
require_relative "strict_lazy/loader"
require_relative "strict_lazy/batch"
require_relative "strict_lazy/facade"
require_relative "strict_lazy/preloader"

# strict_lazy applies the spirit of Rails' +strict_loading+ to computed values.
# Include it in a model, declare values with +lazy_load+, prepare them in the
# controller with +StrictLazy.preload+, and read them via +record.lazy.x+.
# Reading without a preceding preload raises in development/test.
module StrictLazy
  extend ActiveSupport::Concern

  # The baseline policy, set globally (StrictLazy.violation=) or by the Railtie
  # from the environment. with_violation overrides it for the current execution
  # context only; the +violation+ reader returns the override-aware effective
  # value. :raise (dev/test default), :log, or :ignore.
  mattr_accessor :default_violation, default: :raise

  # Fiber/Thread-local override stack for with_violation. thread_mattr_accessor
  # is the public API (it honors config.active_support.isolation_level and
  # isolates parallel test processes); we avoid the :nodoc:
  # ActiveSupport::IsolatedExecutionState. Each thread starts at nil, so readers
  # guard with `|| []`.
  thread_mattr_accessor :violation_overrides, instance_accessor: false

  # The accepted violation policies.
  VALID_VIOLATIONS = %i[raise log ignore].freeze

  # A valid reader is a bare name, optionally a `?` predicate. Setter (`=`),
  # bang (`!`), and operator readers are rejected: the `.lazy` namespace is
  # read-only, and any other form has no valid ivar to back it.
  READER_FORMAT = /\A[A-Za-z_][A-Za-z0-9_]*\??\z/

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
      validate_lazy_load!(reader, from, block)

      loader = Loader.new(reader: reader, sync: sync, default: default, from: from, block: block)
      self.lazy_loaders = lazy_loaders.merge(reader => loader)
    end

    private

    def validate_lazy_load!(reader, from, block)
      raise ArgumentError, "lazy_load #{reader.inspect}: pass either `from:` or a block, not both" if from && block
      raise ArgumentError, "lazy_load #{reader.inspect}: pass either `from:` or a block" unless from || block
      unless READER_FORMAT.match?(reader.to_s)
        raise ArgumentError, "lazy_load #{reader.inspect}: reader must be a bare name or a `?` predicate; " \
                             "the `.lazy` namespace is read-only (no setters, bang, or operator readers)"
      end

      validate_from_defined!(reader, from)
    end

    def validate_from_defined!(reader, from)
      return if from.nil? || respond_to?(from)

      raise ArgumentError, "lazy_load #{reader.inspect}: `from: #{from.inspect}` is not defined on #{name}. " \
                           "Define the class method before the lazy_load declaration."
    end
  end

  # The +.lazy+ namespace facade (memoized per record).
  def lazy
    @_lazy_facade ||= Facade.new(self)
  end

  # The effective policy for the current execution context: the innermost
  # with_violation override if any, otherwise the global baseline. The facade
  # consults this — never read +default_violation+ directly.
  def self.violation
    (violation_overrides || []).last || default_violation
  end

  # Backward-compatible global setter. Sets the baseline only; it does not touch
  # any active with_violation override. Existing callers (and the Railtie) keep
  # working unchanged.
  def self.violation=(mode)
    self.default_violation = validate_violation!(mode)
  end

  # Run the block with +mode+ as the effective policy, restoring the previous
  # state afterward (exception-safe). Overrides nest; an inner call shadows an
  # outer one and unwinds cleanly. Scoped to the current Fiber/Thread, so
  # parallel test processes never interfere.
  #
  #   StrictLazy.with_violation(:ignore) { ... }   # never raises inside
  def self.with_violation(mode)
    # Validate first: an invalid mode raises here, before the stack is touched,
    # so the begin/ensure only ever runs against a successfully pushed frame.
    validated = validate_violation!(mode)
    begin
      pushed = (violation_overrides || []) + [validated]
      self.violation_overrides = pushed
      yield
    ensure
      self.violation_overrides = pushed[0...-1]
    end
  end

  def self.validate_violation!(mode)
    return mode if VALID_VIOLATIONS.include?(mode)

    raise ArgumentError, "StrictLazy violation must be one of #{VALID_VIOLATIONS.inspect}, got #{mode.inspect}"
  end
  private_class_method :validate_violation!

  # Prepare lazy values for a group of records.
  #
  # The +spec+ is a Rails-style list (mirroring ActiveRecord's +preload+): each
  # element is either a reader name (Symbol) prepared on the given records, or a
  # Hash whose keys are associations to traverse and whose values are the spec to
  # apply recursively to the associated records. A Hash value may itself be a
  # Symbol, a Hash, or an array mixing both — so a single level can prepare its
  # own readers and descend into nested associations at once:
  #
  #   StrictLazy.preload(posts,
  #     :comments_count,                              # reader on posts
  #     comments: [:score, { replies: :like_count }] # reader on comments + nested
  #   )
  #
  # With no spec at all, every declared loader on the records is prepared.
  # +sync: true+ loaders resolve immediately; others on first read.
  #
  # Records may mix classes (e.g. STI subtrees, or children gathered across
  # associations): they are grouped by their STI base class so each loader's
  # resolver runs once per declaring class.
  def self.preload(records, *spec)
    Preloader.call(records, spec)
  end
end

require_relative "strict_lazy/railtie" if defined?(Rails::Railtie)
