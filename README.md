# StrictLazy

Strict, explicit preloading for **computed values** — values that `includes` /
`preload` cannot express (external APIs, window functions, cross-table
aggregates). `strict_lazy` applies the spirit of Rails' `strict_loading` to those
values: it forces you to preload them explicitly in the controller, and **raises
in development/test** if you read one without preloading — instead of silently
falling back to N+1.

No `batch-loader` / `N1Loader` / `ar_lazy_preload` dependency. Just
`activesupport`.

## Why

A naive view helper can't "register before the first access", so it quietly
degrades to N+1. Auto-batching gems fix the N+1 but hide the missing preload.
`strict_lazy` takes the opposite stance — **make the preload mandatory and make
forgetting it loud** — so every query stays in the controller and view rendering
issues no hidden queries.

| Tool | Target | On unloaded access |
| --- | --- | --- |
| `includes` / `preload` | associations only | lazy load (can N+1) |
| `strict_loading` (Rails) | associations only | **raise** |
| batch-loader | general | auto-batch, no detection |
| N1Loader (+ar_lazy_preload) | computed values | auto-batch; plain setup silently N+1s |
| **`strict_lazy`** | **computed values** | **raise (immediate detection)** |

## Installation

```ruby
gem "strict_lazy"
```

## Quick start

Define a resolver, declare the value with `lazy_load`, preload in the
controller, and read via `.lazy`.

```ruby
class Post < ApplicationRecord
  include StrictLazy

  # Block resolver: receives (records, loader); call loader.call(record, value)
  # for each record you fulfill. Posts with zero comments never appear in the
  # GROUP BY, so they fall back to default: 0.
  lazy_load :comments_count, default: 0 do |posts, loader|
    by_id = posts.index_by(&:id)
    Comment.where(post_id: by_id.keys).group(:post_id).count.each do |post_id, n|
      loader.call(by_id[post_id], n)
    end
  end

  # from: resolver — a named class method, defined BEFORE the lazy_load. Good for
  # complex/reusable resolvers; dedup FKs yourself.
  def self.resolve_avatar(posts, loader)
    urls = AvatarService.bulk_fetch(posts.map(&:author_id).uniq)
    posts.each { |p| loader.call(p, urls[p.author_id]) }
  end
  lazy_load :avatar, from: :resolve_avatar, sync: true
end
```

```ruby
# controller
@posts = Post.recent.to_a
StrictLazy.preload(@posts)            # all declared loaders
# StrictLazy.preload(@posts, :avatar) # or just some
```

```erb
<%= post.lazy.comments_count %>
<img src="<%= post.lazy.avatar %>">
```

## Nested preload

To prepare lazy values on associated records, pass a Hash to `preload`. The keys
are associations to traverse; the values are the spec to apply to the associated
records (a reader, a Hash, or an array mixing both — the same grammar as the
top level). This mirrors ActiveRecord's `preload` spec.

```ruby
# comments and replies each declare their own lazy_load readers
StrictLazy.preload(@posts,
  :comments_count,                              # reader on @posts
  comments: [:reply_count, { replies: :shout }] # reader on comments + nested
)
```

- Plain symbols apply to the current level; Hash keys descend into associations.
- A Hash-only call (`StrictLazy.preload(@posts, comments: :reply_count)`)
  prepares nothing on `@posts` itself — only the children.
- Associations are batch-loaded to avoid N+1. If the records aren't
  ActiveRecord-backed (e.g. unsaved), preload the association yourself first.
- Records may mix classes (STI subtrees, children gathered across associations);
  they are grouped by STI base class so each resolver runs once per class.
- This traverses **associations** only. Chaining a lazy reader into another lazy
  preload (lazy→lazy) is out of scope — collect those records yourself and call
  `preload` again.

## Eager vs lazy (`sync:`)

- `sync: false` (default): resolution is deferred to the first `.lazy` read, then
  the whole preloaded group is resolved in one shot and memoized.
- `sync: true`: resolved eagerly at `StrictLazy.preload` time.

## Strict detection & `violation`

Reading a value that was never preloaded triggers the `violation` policy:

| mode | behavior |
| --- | --- |
| `:raise` | raise `StrictLazy::UnloadedError` (no wasted query) |
| `:log` | `Rails.logger.warn`, then degrade to a single-record resolve |
| `:ignore` | silently degrade to a single-record resolve (N+1) |

Environment defaults (via the Railtie):

- development / test → `:raise`
- production → `:ignore`

Override globally with `StrictLazy.violation = :log`, or in Rails with
`config.strict_lazy.violation = :log`.

### Scoped overrides — `with_violation`

`StrictLazy.with_violation(mode) { ... }` overrides the effective policy for the
duration of the block, then restores the previous state — even if the block
raises. Overrides nest (an inner call shadows the outer one) and are scoped to
the current Fiber/Thread, so parallel test processes never interfere.

```ruby
StrictLazy.with_violation(:ignore) do
  record.lazy.x  # degrades to a single-record resolve instead of raising
end
```

The three APIs relate as: `StrictLazy.violation=` sets the global **baseline**,
`with_violation` applies a **scoped** override, and the `StrictLazy.violation`
reader returns the **effective** value (innermost override, else the baseline).

### Per-test policy in RSpec

`strict_lazy` ships no implicit RSpec hook — wire it up explicitly so the policy
is visible where it applies. A common setup: model specs don't need preloads
(`:ignore`), while system/request specs keep the strict baseline (`:raise`).

```ruby
# spec/rails_helper.rb
RSpec.configure do |config|
  config.around(:each, type: :model) do |example|
    StrictLazy.with_violation(:ignore) { example.run }
  end
end
```

To relax only a few examples, drive the `around` off a tag instead:

```ruby
RSpec.configure do |config|
  config.around(:each, :ignore_lazy) do |example|
    StrictLazy.with_violation(:ignore) { example.run }
  end
end

it "computes something", :ignore_lazy do
  # ...
end
```

## Defaults

`default:` is written for any record the resolver does not fulfill. Pass a
**callable** for per-record defaults so mutable values are never shared:

```ruby
lazy_load :tags, default: -> { [] } do |records, loader| ... end       # arity 0
lazy_load :slug, default: ->(record) { "p-#{record.id}" } do ... end   # arity 1
```

A static value (`default: 0`) is written as-is.

## Design notes

- **Preload is mandatory.** Detection happens on first access; dev/test raise so
  you catch it immediately.
- **Resolvers are set-level.** A resolver runs over the whole group, not one
  record. FK dedup/mapping is the resolver's responsibility (there is no `key:`).
- **Scope the records.** `preload` should cover the collection once; the same
  loader preloaded on overlapping groups resolves more than once.
- **Definition order (for `from:`).** Define the referenced class method before
  the `lazy_load` declaration. Block resolvers have no such constraint.
- Values live on the record (`@_lazy_<reader>`) and are GC'd with the request —
  no thread-local cache, no middleware.
- **Predicate readers.** `lazy_load :published?` is supported and read as
  `record.lazy.published?`; the `?` is encoded in the ivar (`@_lazy_published_pred`)
  so it does not collide with a plain `published` reader. A reader must be a bare
  name or a `?` predicate — the read-only `.lazy` namespace rejects setter (`=`),
  bang (`!`), and operator reader names at declaration time.

## Agent skill

This repo ships an [agent skill](skills/strict-lazy/) (`SKILL.md`) that teaches
coding agents when and how to apply `strict_lazy`. Install it into your project
with the GitHub CLI:

```sh
gh skill install aki77/strict_lazy
```

> `gh skill` is currently a GitHub CLI preview feature.

Alternatively, if your project already pulls `strict_lazy` in via Bundler, the
[bundler-skills](https://github.com/aki77/bundler-skills) plugin auto-syncs this
skill on `bundle install` — keeping the skill version locked to the gem version.

## Non-Rails usage

Works without Rails: `include StrictLazy`, declare with `lazy_load`, call
`StrictLazy.preload(records)`, read via `record.lazy.x`. Set the policy yourself
with `StrictLazy.violation = :raise` (the default).

## Where it fits

Use `includes` / `strict_loading` for **associations**, `bullet` to detect N+1
in associations, and `strict_lazy` for **computed values** you want preloaded
explicitly and checked strictly.

## Development

After checking out the repo, run `bin/setup`. Then `bundle exec rake` runs specs
and RuboCop. `bundle exec appraisal install && bundle exec appraisal rake spec`
runs the full Rails matrix.

## Contributing

Bug reports and pull requests are welcome on GitHub at
https://github.com/aki77/strict_lazy.

## License

Available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
