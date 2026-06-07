# frozen_string_literal: true

require_relative "lib/strict_lazy/version"

Gem::Specification.new do |spec|
  spec.name = "strict_lazy"
  spec.version = StrictLazy::VERSION
  spec.authors = ["aki"]
  spec.email = ["lala.akira@gmail.com"]

  spec.summary = "Strict, explicit preloading for computed values — raise on unloaded access instead of silent N+1."
  spec.description = <<~DESC
    strict_lazy applies the spirit of Rails' strict_loading to computed values
    (external APIs, window functions, cross-table aggregates) that associations
    cannot express. It forces explicit preloading and raises on unloaded access
    in development/test, so hidden per-record queries never slip into views.
    No batch-loader / N1Loader / ar_lazy_preload dependency — activesupport only.
  DESC
  spec.homepage = "https://github.com/aki77/strict_lazy"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore .rspec spec/ .github/ .rubocop.yml Appraisals gemfiles/ .claude/])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "activesupport", ">= 8.0"
end
