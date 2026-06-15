# strict_lazy API Reference

Supplement to SKILL.md. Covers all `lazy_load` arguments, `StrictLazy.preload`, `violation`, and callable default behavior in detail. Read SKILL.md first for the big picture, then come here to check argument specifics.

## Table of Contents

- [`lazy_load` declaration](#lazy_load-declaration)
- [Resolver — block vs `from:`](#resolver--block-vs-from)
- [`sync:` — deferred vs immediate resolution](#sync--deferred-vs-immediate-resolution)
- [`default:` — value for unresolved records](#default--value-for-unresolved-records)
- [`StrictLazy.preload`](#strictlazypreload)
- [Read order of `record.lazy`](#read-order-of-recordlazy)
- [`violation` policy](#violation-policy)
- [Lifecycle and internal ivars](#lifecycle-and-internal-ivars)
- [Complete implementation example](#complete-implementation-example)

## `lazy_load` declaration

```ruby
lazy_load(reader, from: nil, sync: false, default: nil, &block)
```

- `reader` — the name read via `.lazy.<reader>` (Symbol). No conflict with AR columns of the same name (because no plain method is defined).
- `from:` and `&block` are **mutually exclusive (xor)**. Passing both or neither raises `ArgumentError` at declaration time.
- If the method passed to `from:` is undefined, raises `ArgumentError` at declaration time ("Define the class method before the lazy_load declaration.").

Declarations are merged into `class_attribute :lazy_loaders` and **inherited by STI subclasses**.

## Resolver — block vs `from:`

Both **receive `(records, loader)` and call `loader.call(record, value)` for each resolved record**. The resolver runs **once** for the whole group (not per record).

Block resolvers are `instance_exec`'d on the model class (i.e., `self` is the model class):

```ruby
lazy_load :comments_count, default: 0 do |posts, loader|
  by_id = posts.index_by(&:id)
  Comment.where(post_id: by_id.keys).group(:post_id).count.each do |post_id, n|
    loader.call(by_id[post_id], n)
  end
end
```

`from:` resolvers are called as class methods via `public_send`. Better for complex or reusable cases. **Must be defined before the declaration**:

```ruby
def self.resolve_avatar(posts, loader)
  urls = AvatarService.bulk_fetch(posts.map(&:author_id).compact.uniq)
  posts.each { |p| loader.call(p, urls[p.author_id]) }
end
lazy_load :avatar, from: :resolve_avatar, sync: true
```

FK deduplication and ID→value mapping are **the resolver's responsibility**. The gem has no `key:` mechanism.

## `sync:` — deferred vs immediate resolution

- `sync: false` (default) — defers resolution until the first `.lazy` read. At first read, resolves the entire group at once and memoizes. If nothing is read in the list, zero queries.
- `sync: true` — resolves immediately at `StrictLazy.preload` time. Use when you want to hit an external API early or guarantee retrieval before the response.

Either way, the result is stored in the record's `@_lazy_<reader>` ivar; subsequent reads are zero queries.

## `default:` — value for unresolved records

The value written to records that `loader.call` was never called for.

- **Static values** (`default: 0`, `default: "n/a"`) — written to all records as-is.
- **Callable** — a **factory** called per record. Use to avoid sharing mutable values (`[]`, `{}`) across records.
  - arity 0: `default: -> { [] }` — new instance every time.
  - arity 1: `default: ->(record) { "post-#{record.id}" }` — receives the record.

```ruby
lazy_load :tags, default: -> { [] } do |records, loader| ... end       # separate [] per record
lazy_load :slug, default: ->(record) { "p-#{record.id}" } do ... end   # record-dependent default
```

Passing a mutable value directly like `default: []` shares the same object across all records — always use a callable instead.

## `StrictLazy.preload`

```ruby
StrictLazy.preload(records, *spec)
```

- `records` — array of records (single records are wrapped with `Array()`). An `ActiveRecord::Relation` can also be passed directly — the internal `Array()` evaluates it (no `.to_a` needed). Does nothing if empty.
- `spec` — a Rails-style list (mirrors ActiveRecord's `preload`). Each element is either:
  - a **reader name** (Symbol) — prepared on `records`, or
  - a **Hash** — keys are associations to traverse, values are the spec applied to the associated records (recursively). A Hash value may be a Symbol, a Hash, or an array mixing both.
- When `spec` is **entirely empty**, **all declared loaders** on `records` are prepared. A Hash-only spec (e.g. `preload(posts, comments: :reply_count)`) prepares **nothing** on `records` itself — only the children.
- Creates a `Batch` for each loader and sets it on `@_batch_<reader>` for all records. Loaders with `sync: true` are immediately `resolve!`'d here.
- Records are grouped by **STI base class** (`class.base_class`), so each loader's resolver runs once per declaring class. A mixed-class array (STI subtrees, or children gathered across associations) is handled correctly.
- Associations are batch-loaded via `ActiveRecord::Associations::Preloader` to avoid N+1 while traversing. Non-AR records skip this (preload the association yourself first). Traversing a name that isn't an association raises `ArgumentError`.

```ruby
# reader on posts + reader on comments + reader on comments.replies
StrictLazy.preload(@posts, :comments_count, comments: [:reply_count, { replies: :shout }])
```

Note: **preloading the same loader for overlapping groups twice** causes the resolver to run multiple times. Call it once to cover the collection you read in the view.

Out of scope: chaining a lazy reader's result into another lazy preload (lazy→lazy). `preload` traverses **associations** only. If a `lazy_load` returns records you want to preload further, collect them yourself and call `preload` again.

### Why passing a `Relation` directly works

`preload` writes the `@_batch_<reader>` ivar onto each record object, so the records you preload and the records you read in the view must be the **same objects**. A `Relation` satisfies this:

1. `Array(relation)` triggers `relation.to_a`, which loads the relation and **caches the result** (`relation.loaded? == true`).
2. Re-iterating the same loaded `Relation` (e.g. `@posts.each` in the view) returns the **same cached objects** — not a re-query, not new instances.

So `@posts = Post.recent; StrictLazy.preload(@posts)` then `@posts.each` in the view reads the very objects that got the batch ivar. The `Array()` call inside `preload` warms the relation's cache as a side effect, so no explicit `.to_a` is needed.

The one caveat (same as the "match the collection" rule above): evaluating a **different** relation in the view — e.g. preloading `Post.recent` but iterating `Post.recent` again as a fresh query — produces new objects without the batch ivar, which then raise under `violation: :raise`. Keep the preloaded relation in a variable and reuse it.

## Read order of `record.lazy`

Resolution order for `record.lazy.x` (`Facade#method_missing`):

1. `@_lazy_<reader>` already set → return it (already resolved / sync / group-resolved).
2. `@_batch_<reader>` present → resolve the whole group once and return (lazy resolution).
3. No batch and `violation: :raise` → raise `UnloadedError` (no wasted queries).
4. No batch and non-strict → degrade to 1-record resolution (fallback, N+1).

`record.lazy` itself generates a `Facade` once and memoizes it (`@_lazy_facade`).
`record.lazy.respond_to?(:x)` reflects declared loaders.

## `violation` policy

Behavior when `.lazy.x` is read without a preload (cases 3/4 above).

| mode | behavior |
| --- | --- |
| `:raise` | Raises `StrictLazy::UnloadedError`. No wasted queries. |
| `:log` | `Rails.logger.warn("[StrictLazy] ... read without preload (degraded to N+1)")`, then resolves 1 record. |
| `:ignore` | Silently resolves 1 record (N+1). |

Configuration:

- Global: `StrictLazy.violation = :log`
- Rails: `config.strict_lazy.violation = :log` (Railtie applies at initialization)
- Railtie environment defaults: production → `:ignore`, everything else (development/test) → `:raise`

The intent of `:raise` is "fail fast during development when a preload is missing"; `:ignore` is "don't crash in production, degrade to N+1 and keep running".

## Lifecycle and internal ivars

- `@_lazy_<reader>` — the resolved value.
- `@_batch_<reader>` — shared `Batch` reference for the group.
- `@_lazy_facade` — the `Facade` for `.lazy` (memoized).

All are instance variables on the record, so they are **GC'd with the request**. No thread-local cache, no middleware, no global registry. `Batch` writes values directly to each record's ivar, so it holds no intermediate Hash and does not depend on record hash equality (= **works with unsaved records**).

## Complete implementation example

```ruby
# app/models/post.rb
class Post < ApplicationRecord
  include StrictLazy

  # Cross-table aggregation (1 query via GROUP BY)
  lazy_load :comments_count, default: 0 do |posts, loader|
    by_id = posts.index_by(&:id)
    Comment.where(post_id: by_id.keys).group(:post_id).count.each do |post_id, n|
      loader.call(by_id[post_id], n)
    end
  end

  # External API (bulk_fetch IDs together, immediate resolution)
  def self.resolve_avatar(posts, loader)
    urls = AvatarService.bulk_fetch(posts.map(&:author_id).compact.uniq)
    posts.each { |p| loader.call(p, urls[p.author_id]) }
  end
  lazy_load :avatar, from: :resolve_avatar, sync: true
end
```

```ruby
# app/controllers/posts_controller.rb
def index
  @posts = Post.recent         # an ActiveRecord::Relation is fine (no .to_a needed)
  StrictLazy.preload(@posts)   # prepares comments_count and avatar
end
```

```erb
<%# app/views/posts/index.html.erb %>
<% @posts.each do |post| %>
  <span><%= post.lazy.comments_count %></span>
  <img src="<%= post.lazy.avatar %>">
<% end %>
```

If you forget the preload and read `post.lazy.comments_count`, development/test raises
`StrictLazy::UnloadedError`, prompting you to add `StrictLazy.preload` in the controller.
