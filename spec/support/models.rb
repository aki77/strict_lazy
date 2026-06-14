# frozen_string_literal: true

# A fake external service to prove "values associations cannot express".
module AvatarService
  class << self
    attr_accessor :calls

    def bulk_fetch(author_ids)
      self.calls = (calls || 0) + 1
      author_ids.to_h { |id| [id, "https://avatars.example/#{id}.png"] }
    end

    def reset!
      self.calls = 0
    end
  end
end

class Author < ActiveRecord::Base
  has_many :posts
end

class Comment < ActiveRecord::Base
  belongs_to :post
end

class Post < ActiveRecord::Base
  include StrictLazy

  belongs_to :author, optional: true
  has_many :comments

  # Block resolver: fulfill via a single grouped count. Posts with zero comments
  # never appear in the GROUP BY, so they fall back to default: 0.
  lazy_load :comments_count, default: 0 do |posts, loader|
    by_id = posts.index_by(&:id)
    Comment.where(post_id: by_id.keys).group(:post_id).count.each do |post_id, n|
      loader.call(by_id[post_id], n)
    end
  end

  # from: resolver. FK-based, deduped by the resolver itself, eager.
  def self.resolve_avatar(posts, loader)
    urls = AvatarService.bulk_fetch(posts.map(&:author_id).compact.uniq)
    posts.each { |p| loader.call(p, urls[p.author_id]) }
  end
  lazy_load :avatar, from: :resolve_avatar, sync: true

  # Mutable default via a callable factory (one fresh array per record).
  lazy_load :tags, default: -> { [] } do |posts, loader|
    # Intentionally fulfills nothing, to exercise the default path.
  end

  # Callable default that receives the record (arity 1).
  lazy_load :slug, default: ->(post) { "post-#{post.id}" } do |posts, loader|
    # Fulfills nothing.
  end

  # Predicate (`?`) reader: like comments_count but returns a boolean.
  lazy_load :commented?, default: false do |posts, loader|
    ids = Comment.where(post_id: posts.map(&:id)).distinct.pluck(:post_id).to_set
    posts.each { |p| loader.call(p, ids.include?(p.id)) }
  end

  # Same base name without `?`, to prove the predicate ivar does not collide.
  lazy_load :commented, default: :none do |posts, loader|
    posts.each { |p| loader.call(p, :plain) }
  end
end

# STI subclass to prove lazy_loaders is inherited.
class SpecialPost < Post
end
