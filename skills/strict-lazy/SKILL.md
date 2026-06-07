---
name: strict-lazy
description: "How to use the strict_lazy gem to eliminate N+1 for 'computed values' (external APIs, window functions, cross-table aggregations) that cannot be expressed with preload/includes — by requiring explicit preloads and raising on unpreloaded reads in dev/test. Use when: (1) fixing N+1 in a list where the cause is aggregation/external API/computed methods rather than associations, (2) implementing pre-loading for such values. Out of scope: N+1 expressible via associations (use includes/preload/strict_loading instead)."
---

# strict_lazy

A gem that brings `strict_loading` to **computed values**. Forces controllers to explicitly preload values that cannot be expressed as associations, and raises on unpreloaded reads in dev/test. Only depends on `activesupport`.

## First: determine applicability

If the value can be expressed via `belongs_to`/`has_many`, use the standard solution instead of strict_lazy. Misuse adds unnecessary complexity.

| N+1 cause | Tool |
| --- | --- |
| Traversing associations | `includes` / `preload` / `eager_load` |
| Detecting unloaded associations | `strict_loading` / `bullet` |
| **Computed values not expressible as associations** | **strict_lazy** |

strict_lazy is only for values that can't be written with preload:
- External APIs: things that can be fetched in bulk like `Svc.bulk_fetch(ids)`
- Window functions / raw SQL: e.g. `ROW_NUMBER() OVER (...)`
- Cross-table aggregations: e.g. `group(:post_id).count` (prefer `counter_cache` when it suffices)

## Usage (4 required pieces — missing any one breaks it)

### 1. Declare in the model

The resolver is either a **block** or **`from:` (class method name)** — mutually exclusive. Both receive `(records, loader)` and call `loader.call(record, value)` for each resolved record. **Runs exactly once for the whole group**, so consolidate into 1 query/1 API call here.

```ruby
class Post < ApplicationRecord
  include StrictLazy

  lazy_load :comments_count, default: 0 do |posts, loader|
    by_id = posts.index_by(&:id)
    Comment.where(post_id: by_id.keys).group(:post_id).count.each do |post_id, n|
      loader.call(by_id[post_id], n)
    end
  end

  # from: must be defined before lazy_load. FK deduplication is the resolver's responsibility (no key: option).
  def self.resolve_avatar(posts, loader)
    urls = AvatarService.bulk_fetch(posts.map(&:author_id).compact.uniq)
    posts.each { |p| loader.call(p, urls[p.author_id]) }
  end
  lazy_load :avatar, from: :resolve_avatar, sync: true
end
```

Records not called with `loader.call` receive the `default:` value (how Posts with 0 comments get `default: 0` when absent from GROUP BY results).

### 2. Preload in the controller

```ruby
@posts = Post.recent.to_a
StrictLazy.preload(@posts)             # all loaders. preload(@posts, :avatar) for a subset
```

Match the collection you read in the view. `sync: false` (default) resolves lazily on first `.lazy` read and memoizes; `sync: true` resolves immediately at preload time.

### 3. Read via `.lazy.` in the view

```erb
<%= post.lazy.comments_count %>
```

No plain method is defined. Always go through `.lazy.`.

### 4. Forgotten preloads raise

`violation` on unpreloaded reads: `:raise` (default dev/test — no wasted queries) / `:log` (warn then resolve 1 record) / `:ignore` (default prod — silently resolves 1 record = N+1). Override with `StrictLazy.violation=` or `config.strict_lazy.violation`.

## Pitfalls

- Forgetting `.lazy.` → reads a normal method/column, preload has no effect
- Defining `from:` after `lazy_load` → raises at declaration time (no restriction for blocks)
- Writing the resolver one record at a time → N+1 persists. Use `records` to consolidate into one call
- `default: []` and other mutable shared objects → use callable: `-> { [] }` (arity 0) / `->(r) { ... }` (arity 1). Static values are fine as-is
- Preload group and view collection don't match → unpreloaded records raise

For full argument details and behavior, see [references/api.md](references/api.md).
