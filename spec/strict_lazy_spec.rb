# frozen_string_literal: true

RSpec.describe StrictLazy do
  let(:author) { Author.create!(name: "A") }

  before { AvatarService.reset! }

  it "has a version number" do
    expect(StrictLazy::VERSION).not_to be_nil
  end

  def make_posts(n, with_comments: {})
    posts = Array.new(n) { |i| Post.create!(author: author, title: "t#{i}") }
    with_comments.each do |index, count|
      count.times { Comment.create!(post: posts.fetch(index), body: "c") }
    end
    posts
  end

  describe "lazy resolution (default sync: false)" do
    it "issues 0 queries until read, 1 query on first read, then memoizes" do
      posts = make_posts(3, with_comments: { 0 => 2, 1 => 1 })
      StrictLazy.preload(posts, :comments_count)

      expect(count_queries { posts }).to eq(0)

      values = nil
      expect(count_queries { values = posts.map { |p| p.lazy.comments_count } }).to eq(1)
      expect(values).to eq([2, 1, 0]) # post 2 has no comments -> default 0

      expect(count_queries { posts.map { |p| p.lazy.comments_count } }).to eq(0)
    end
  end

  describe "eager resolution (sync: true)" do
    it "resolves at preload time; read returns the value with no service re-call" do
      posts = make_posts(2)
      StrictLazy.preload(posts, :avatar)

      expect(AvatarService.calls).to eq(1)
      expect(posts.first.lazy.avatar).to eq("https://avatars.example/#{author.id}.png")
      expect(AvatarService.calls).to eq(1) # not re-called on read
    end
  end

  describe "unused lazy loader" do
    it "issues 0 queries when never read" do
      posts = make_posts(3, with_comments: { 0 => 1 })
      StrictLazy.preload(posts, :comments_count)
      expect(count_queries { posts }).to eq(0)
    end
  end

  describe "strict detection" do
    it "raises UnloadedError on first access without preload, with no wasted query" do
      post = make_posts(1).first
      queries = 0
      expect do
        queries = count_queries { post.lazy.comments_count }
      end.to raise_error(StrictLazy::UnloadedError, /Post#comments_count/)
      expect(queries).to eq(0)
    end
  end

  describe "no false positives" do
    it "does not raise across independent preloads on a single-record page" do
      posts = make_posts(1, with_comments: { 0 => 4 })
      StrictLazy.preload(posts, :comments_count)
      StrictLazy.preload(posts, :avatar)
      expect(posts.first.lazy.comments_count).to eq(4)
      expect(posts.first.lazy.avatar).to be_a(String)
    end
  end

  describe "from:/block validation (xor)" do
    it "raises at declaration time for both, neither, and undefined from:" do
      expect do
        Class.new(ActiveRecord::Base) do
          self.table_name = "posts"
          include StrictLazy

          lazy_load(:x, from: :foo) { |*| }
        end
      end.to raise_error(ArgumentError, /not both/)

      expect do
        Class.new(ActiveRecord::Base) do
          self.table_name = "posts"
          include StrictLazy

          lazy_load :x
        end
      end.to raise_error(ArgumentError, /either `from:` or a block/)

      expect do
        Class.new(ActiveRecord::Base) do
          self.table_name = "posts"
          include StrictLazy

          lazy_load :x, from: :not_defined
        end
      end.to raise_error(ArgumentError, /not defined/)
    end
  end

  describe ".lazy namespace" do
    it "does not grow a bare method; respond_to? reflects the namespace" do
      post = make_posts(1).first
      expect(post.respond_to?(:comments_count)).to be(true) # AR column, not our doing
      expect(post).not_to respond_to(:avatar)
      expect(post.lazy).to respond_to(:avatar)
      expect(post.lazy).not_to respond_to(:nonexistent)
    end
  end

  describe "AR column non-collision" do
    it "lets a same-named column and lazy reader coexist" do
      posts = make_posts(2, with_comments: { 0 => 5 })
      StrictLazy.preload(posts, :comments_count)
      # The column default is -1; the lazy value is the computed count.
      expect(posts.first.comments_count).to eq(-1)
      expect(posts.first.lazy.comments_count).to eq(5)
    end
  end

  describe "STI inheritance" do
    it "inherits lazy_loaders into subclasses" do
      expect(SpecialPost.lazy_loaders.keys).to include(:comments_count, :avatar)
      special = SpecialPost.create!(author: author, title: "s")
      Comment.create!(post: special, body: "c")
      StrictLazy.preload([special], :comments_count)
      expect(special.lazy.comments_count).to eq(1)
    end
  end

  describe "fulfill and mapping" do
    it "writes per record, defaults unfulfilled, dedups FK in 1 service call, supports unsaved records" do
      posts = make_posts(3, with_comments: { 1 => 2 })
      StrictLazy.preload(posts, :comments_count)
      expect(posts.map { |p| p.lazy.comments_count }).to eq([0, 2, 0])

      # FK dedup: 3 posts share one author -> a single bulk_fetch.
      StrictLazy.preload(posts, :avatar)
      expect(AvatarService.calls).to eq(1)

      # Unsaved records work (no hash-equality dependence).
      unsaved = [Post.new(author: author), Post.new(author: author)]
      StrictLazy.preload(unsaved, :avatar)
      expect(unsaved.first.lazy.avatar).to eq("https://avatars.example/#{author.id}.png")
    end
  end

  describe "violation modes" do
    let(:post) { make_posts(1).first }

    it ":raise raises" do
      StrictLazy.violation = :raise
      expect { post.lazy.comments_count }.to raise_error(StrictLazy::UnloadedError)
    end

    it ":ignore degrades silently to a single-record resolve" do
      StrictLazy.violation = :ignore
      Comment.create!(post: post, body: "c")
      expect(post.lazy.comments_count).to eq(1)
    end

    it ":log warns and still resolves" do
      StrictLazy.violation = :log
      expect(post.lazy.comments_count).to eq(0)
    end

    it "raises ArgumentError for an invalid mode" do
      expect { StrictLazy.violation = :bogus }.to raise_error(ArgumentError, /must be one of/)
    end
  end

  describe ".with_violation" do
    let(:post) { make_posts(1).first }

    # The spec_helper resets the baseline to :raise before each example.
    it "overrides the effective policy inside the block, then restores it" do
      Comment.create!(post: post, body: "c")

      value = nil
      StrictLazy.with_violation(:ignore) do
        expect(StrictLazy.violation).to eq(:ignore)
        value = post.lazy.comments_count # would raise under :raise
      end

      expect(value).to eq(1)
      expect(StrictLazy.violation).to eq(:raise)
    end

    it "restores the previous policy even when the block raises" do
      expect do
        StrictLazy.with_violation(:ignore) { raise "boom" }
      end.to raise_error("boom")
      expect(StrictLazy.violation).to eq(:raise)
    end

    it "nests: an inner override shadows the outer and unwinds cleanly" do
      StrictLazy.with_violation(:ignore) do
        StrictLazy.with_violation(:raise) do
          expect(StrictLazy.violation).to eq(:raise)
          expect { post.lazy.comments_count }.to raise_error(StrictLazy::UnloadedError)
        end
        expect(StrictLazy.violation).to eq(:ignore)
      end
    end

    it "is independent of the baseline setter while active" do
      StrictLazy.with_violation(:ignore) do
        StrictLazy.violation = :log # changes the baseline only
        expect(StrictLazy.violation).to eq(:ignore) # override still wins
      end
      expect(StrictLazy.violation).to eq(:log)
    end

    it "raises ArgumentError for an invalid mode without touching the stack" do
      expect { StrictLazy.with_violation(:bogus) { :unreached } }.to raise_error(ArgumentError, /must be one of/)
      expect(StrictLazy.violation).to eq(:raise)
    end

    it "does not leak the override to other threads" do
      seen = nil
      StrictLazy.with_violation(:ignore) do
        Thread.new { seen = StrictLazy.violation }.join
      end
      expect(seen).to eq(:raise)
    end
  end

  describe "request boundary" do
    it "does not leak batches or values across separate record groups" do
      group_a = make_posts(2, with_comments: { 0 => 3 })
      StrictLazy.preload(group_a, :comments_count)
      expect(group_a.first.lazy.comments_count).to eq(3)

      # A fresh group with its own (missing) preload still raises.
      group_b = make_posts(1, with_comments: { 0 => 9 })
      expect { group_b.first.lazy.comments_count }.to raise_error(StrictLazy::UnloadedError)
    end
  end

  describe "predicate (?) reader names" do
    it "resolves a `?` reader and returns its value" do
      posts = make_posts(2, with_comments: { 0 => 1 })
      StrictLazy.preload(posts, :commented?)
      expect(posts[0].lazy.commented?).to be(true)
    end

    it "writes the default for unfulfilled records" do
      posts = make_posts(2, with_comments: { 0 => 1 })
      StrictLazy.preload(posts, :commented?)
      expect(posts[1].lazy.commented?).to be(false)
    end

    it "does not collide with a same-named non-predicate reader" do
      posts = make_posts(1, with_comments: { 0 => 1 })
      StrictLazy.preload(posts, :commented?)
      StrictLazy.preload(posts, :commented)
      expect(posts.first.lazy.commented?).to be(true)
      expect(posts.first.lazy.commented).to eq(:plain)
    end

    it "preloads by predicate reader symbol without KeyError" do
      posts = make_posts(1, with_comments: { 0 => 1 })
      expect { StrictLazy.preload(posts, :commented?) }.not_to raise_error
      expect(posts.first.lazy.commented?).to be(true)
    end

    it "raises UnloadedError when read without preload" do
      post = make_posts(1).first
      expect { post.lazy.commented? }.to raise_error(StrictLazy::UnloadedError, /Post#commented\?/)
    end

    it "reflects the predicate reader in respond_to?" do
      post = make_posts(1).first
      expect(post.lazy).to respond_to(:commented?)
      expect(post.lazy).not_to respond_to(:nonexistent?)
    end
  end

  describe "invalid reader names" do
    def declare(reader)
      Class.new(ActiveRecord::Base) do
        self.table_name = "posts"
        include StrictLazy

        lazy_load(reader) { |*| }
      end
    end

    it "rejects setter (=), bang (!), and operator readers at declaration time" do
      expect { declare(:foo=) }.to raise_error(ArgumentError, /read-only/)
      expect { declare(:foo!) }.to raise_error(ArgumentError, /read-only/)
      expect { declare(:[]) }.to raise_error(ArgumentError, /bare name/)
    end
  end

  describe "callable default" do
    it "produces a fresh instance per record for arity 0 (no shared mutable)" do
      posts = make_posts(2)
      StrictLazy.preload(posts, :tags)
      a = posts[0].lazy.tags
      b = posts[1].lazy.tags
      expect(a).to eq([])
      expect(a).not_to equal(b) # not the same object
      a << :x
      expect(b).to eq([])
    end

    it "passes the record for arity 1" do
      posts = make_posts(2)
      StrictLazy.preload(posts, :slug)
      expect(posts.map { |p| p.lazy.slug }).to eq(posts.map { |p| "post-#{p.id}" })
    end
  end

  describe "nested preload" do
    # Build posts -> comments -> replies with given fan-out counts. Each test
    # names only the levels it exercises; the rest default to none.
    def make_tree(post_count:, comments_per_post: 0, replies_per_comment: 0)
      posts = Array.new(post_count) { |i| Post.create!(author: author, title: "t#{i}") }
      posts.each do |post|
        comments_per_post.times do
          comment = Comment.create!(post: post, body: "c")
          replies_per_comment.times { Reply.create!(comment: comment, body: "r") }
        end
      end
      posts
    end

    it "preloads a reader on the parent and on the nested association" do
      posts = make_tree(post_count: 2, comments_per_post: 2)
      comments = posts.flat_map(&:comments)

      StrictLazy.preload(posts, :comments_count, comments: :reply_count)

      expect(posts.map { |p| p.lazy.comments_count }).to eq([2, 2])
      # reply_count resolves for the whole comment group in one query, no N+1.
      expect(count_queries { comments.each { |c| c.lazy.reply_count } }).to eq(1)
      expect(comments.map { |c| c.lazy.reply_count }).to all(eq(0))
    end

    it "prepares a parent reader and a deeper association at the same level" do
      posts = make_tree(post_count: 1, comments_per_post: 2, replies_per_comment: 3)
      comments = posts.flat_map(&:comments)
      replies = comments.flat_map(&:replies)

      StrictLazy.preload(posts, comments: [:reply_count, { replies: :shout }])

      expect(comments.map { |c| c.lazy.reply_count }).to all(eq(3))
      expect(replies.map { |r| r.lazy.shout }).to all(eq("R"))
    end

    it "descends multiple association levels" do
      posts = make_tree(post_count: 2, comments_per_post: 1, replies_per_comment: 2)
      replies = posts.flat_map(&:comments).flat_map(&:replies)

      StrictLazy.preload(posts, comments: { replies: :shout })

      expect(count_queries { replies.each { |r| r.lazy.shout } }).to eq(0)
      expect(replies.map { |r| r.lazy.shout }).to all(eq("R"))
    end

    it "traverses associations without N+1" do
      posts = make_tree(post_count: 5, comments_per_post: 3)
      # Reload so the comments association starts unloaded (no association cache).
      posts = Post.where(id: posts.map(&:id)).to_a

      # preload batch-loads the comments association in a single query (the
      # reply_count resolver is deferred to first read since it is async).
      expect(count_queries { StrictLazy.preload(posts, comments: :reply_count) }).to eq(1)
      # First read resolves reply_count for the whole comment group in one query.
      comments = posts.flat_map(&:comments)
      expect(count_queries { comments.each { |c| c.lazy.reply_count } }).to eq(1)
    end

    it "does not prepare the parent's loaders when only a Hash is given" do
      posts = make_tree(post_count: 2, comments_per_post: 1)

      StrictLazy.preload(posts, comments: :reply_count)

      # The parent (Post) gets no batch, so reading a Post reader still raises.
      expect { posts.first.lazy.comments_count }.to raise_error(StrictLazy::UnloadedError)
    end

    it "raises ArgumentError for an unknown association" do
      posts = make_tree(post_count: 1)

      expect { StrictLazy.preload(posts, nonexistent: :x) }
        .to raise_error(ArgumentError, /not an association/)
    end

    it "no-ops when the association yields no children" do
      posts = make_tree(post_count: 2)

      expect { StrictLazy.preload(posts, comments: :reply_count) }.not_to raise_error
    end
  end

  describe "mixed-class preload (STI base grouping)" do
    it "resolves loaders once per declaring base class for a mixed array" do
      plain = Post.create!(author: author, title: "p")
      special = SpecialPost.create!(author: author, title: "s")
      Comment.create!(post: plain, body: "c")
      Comment.create!(post: special, body: "c")
      Comment.create!(post: special, body: "c")

      StrictLazy.preload([plain, special], :comments_count)

      expect(plain.lazy.comments_count).to eq(1)
      expect(special.lazy.comments_count).to eq(2)
    end
  end
end
