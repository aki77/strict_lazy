# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in strict_lazy.gemspec
gemspec

gem "irb"
gem "rake", "~> 13.0"

gem "rspec", "~> 3.0"

gem "rubocop", "~> 1.21"
gem "rubocop-rspec", require: false

# Integration tests run against a real ActiveRecord + sqlite3 stack.
gem "activerecord", ">= 8.0"
gem "sqlite3"

# Cross-version (Rails 8.0–8.1) test matrix.
gem "appraisal"
