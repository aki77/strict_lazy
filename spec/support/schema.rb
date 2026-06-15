# frozen_string_literal: true

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")

ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :authors, force: true do |t|
    t.string :name
  end

  create_table :posts, force: true do |t|
    t.integer :author_id
    t.string :title
    # A real column intentionally sharing a name with a lazy reader,
    # to prove .lazy access does not collide with AR attributes.
    t.integer :comments_count, default: -1
    t.string :type # STI
  end

  create_table :comments, force: true do |t|
    t.integer :post_id
    t.string :body
  end

  create_table :replies, force: true do |t|
    t.integer :comment_id
    t.string :body
  end
end
