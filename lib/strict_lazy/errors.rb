# frozen_string_literal: true

module StrictLazy
  # Base error for the gem.
  class Error < StandardError; end

  # Raised when a lazy value is read without a preceding StrictLazy.preload
  # while +violation+ is +:raise+ (the default in development/test).
  class UnloadedError < Error; end
end
