# strict_lazy API リファレンス

SKILL.md の補足。`lazy_load` の全引数、`StrictLazy.preload`、`violation`、callable default の
詳細挙動をまとめる。SKILL.md で全体像をつかんだ上で、引数の細部を確認したいときに読む。

## 目次

- [`lazy_load` の宣言](#lazy_load-の宣言)
- [リゾルバ — ブロック vs `from:`](#リゾルバ--ブロック-vs-from)
- [`sync:` — 遅延 vs 即時解決](#sync--遅延-vs-即時解決)
- [`default:` — 未充足レコードの値](#default--未充足レコードの値)
- [`StrictLazy.preload`](#strictlazypreload)
- [`record.lazy` の読み取り順序](#recordlazy-の読み取り順序)
- [`violation` ポリシー](#violation-ポリシー)
- [ライフサイクルと内部 ivar](#ライフサイクルと内部-ivar)
- [完全な実装例](#完全な実装例)

## `lazy_load` の宣言

```ruby
lazy_load(reader, from: nil, sync: false, default: nil, &block)
```

- `reader` — `.lazy.<reader>` で読む名前 (Symbol)。同名の AR カラムがあっても衝突しない
  (素のメソッドを生やさないため)。
- `from:` と `&block` は **排他 (xor)**。両方渡す/どちらも渡さないと宣言時に `ArgumentError`。
- `from:` に渡したメソッドが未定義だと宣言時に `ArgumentError` (「Define the class method
  before the lazy_load declaration.」)。

宣言は `class_attribute :lazy_loaders` にマージされ、**STI サブクラスに継承** される。

## リゾルバ — ブロック vs `from:`

どちらも **`(records, loader)` を受け取り、解決できた各レコードについて `loader.call(record, value)`
を呼ぶ**。リゾルバはグループ全体に対して **1回** 実行される (1レコードずつではない)。

ブロックリゾルバはモデルクラス上で `instance_exec` される (= `self` がモデルクラス):

```ruby
lazy_load :comments_count, default: 0 do |posts, loader|
  by_id = posts.index_by(&:id)
  Comment.where(post_id: by_id.keys).group(:post_id).count.each do |post_id, n|
    loader.call(by_id[post_id], n)
  end
end
```

`from:` リゾルバはクラスメソッドとして `public_send` される。複雑/再利用するときに向く。
**宣言より前に定義** すること:

```ruby
def self.resolve_avatar(posts, loader)
  urls = AvatarService.bulk_fetch(posts.map(&:author_id).compact.uniq)
  posts.each { |p| loader.call(p, urls[p.author_id]) }
end
lazy_load :avatar, from: :resolve_avatar, sync: true
```

FK の重複排除・ID→値のマッピングは **リゾルバの責任**。gem 側に `key:` のような仕組みはない。

## `sync:` — 遅延 vs 即時解決

- `sync: false` (デフォルト) — 最初の `.lazy` 読み取りまで解決を遅延。最初の読み取り時に
  グループ全体を一気に解決してメモ化。一覧で1つも読まれなければクエリは0。
- `sync: true` — `StrictLazy.preload` の時点で即解決。外部APIを早めに叩く/レスポンス前に
  確実に取得しておきたいときに使う。

どちらも結果はレコードの `@_lazy_<reader>` に乗り、2回目以降の読み取りはクエリ0。

## `default:` — 未充足レコードの値

リゾルバが `loader.call` を呼ばなかったレコードに書かれる値。

- **静的値** (`default: 0`、`default: "n/a"`) — そのまま全レコードに書かれる。
- **callable** — レコードごとに呼ばれる **ファクトリ**。mutable な値 (`[]`, `{}`) を共有しないために使う。
  - arity 0: `default: -> { [] }` — 毎回新しいインスタンス。
  - arity 1: `default: ->(record) { "post-#{record.id}" }` — レコードを受け取る。

```ruby
lazy_load :tags, default: -> { [] } do |records, loader| ... end       # 各レコードに別の []
lazy_load :slug, default: ->(record) { "p-#{record.id}" } do ... end   # レコード依存の既定値
```

`default: []` のように mutable をそのまま渡すと全レコードで同一オブジェクトを共有してしまうので、
必ず callable を使う。

## `StrictLazy.preload`

```ruby
StrictLazy.preload(records, *readers)
```

- `records` — レコード配列 (単体も `Array()` でラップされる)。`ActiveRecord::Relation` もそのまま渡せる（内部の `Array()` が評価するので `.to_a` 不要）。空なら何もしない。
- `readers` 省略時は **宣言済みの全ローダー** を準備。指定すると一部だけ。
- 各ローダーについて `Batch` を作り、全レコードの `@_batch_<reader>` にセット。
  `sync: true` のものはここで即 `resolve!`。
- モデルは `records.first.class` から決まる。**同一モデルのレコード群** を渡す前提。

注意: 同じローダーを **重複するグループに2回 preload** すると、その分リゾルバが複数回走る。
ビューで読むコレクションを1回でカバーするように呼ぶ。

### Relation をそのまま渡してよい理由

`preload` は各レコードオブジェクトに `@_batch_<reader>` ivar を書き込むため、preload するレコードとビューで読むレコードは **同一オブジェクト** である必要がある。`Relation` はこれを満たす:

1. `Array(relation)` が `relation.to_a` を発火させ、Relation をロードして **結果をキャッシュ** する（`relation.loaded? == true`）。
2. ロード済みの同じ `Relation` を再列挙しても（ビューでの `@posts.each` など）、**キャッシュされた同一オブジェクト** が返る ── 再クエリも新規インスタンス生成も起きない。

よって `@posts = Post.recent; StrictLazy.preload(@posts)` のあとビューで `@posts.each` すれば、batch ivar が仕込まれたまさにそのオブジェクトを読む。`preload` 内の `Array()` 呼び出しが副作用で Relation のキャッシュを温めるので、明示的な `.to_a` は要らない。

唯一の注意点（上の「ビューで読むコレクションと一致させる」と同じ）: ビューで **別の Relation** を評価する ── 例えば `Post.recent` を preload したのにビューで再び `Post.recent` を新たなクエリとして回す ── と、batch ivar を持たない新規オブジェクトが生成され、`violation: :raise` では raise する。preload した Relation は変数に保持して使い回すこと。

## `record.lazy` の読み取り順序

`record.lazy.x` の解決は次の順 (`Facade#method_missing`):

1. `@_lazy_<reader>` が既にセット済み → それを返す (解決済み/即時/グループ解決済み)。
2. `@_batch_<reader>` がある → グループ全体を1回解決して返す (遅延解決)。
3. batch がなく `violation: :raise` → `UnloadedError` (無駄クエリなし)。
4. batch がなく非 strict → 1レコード解決に退化 (フォールバック、N+1)。

`record.lazy` 自体は `Facade` を1回だけ生成してメモ化 (`@_lazy_facade`)。
`record.lazy.respond_to?(:x)` は宣言済みローダーを反映する。

## `violation` ポリシー

プリロードなしで `.lazy.x` を読んだときの挙動 (上記の 3/4)。

| mode | 挙動 |
| --- | --- |
| `:raise` | `StrictLazy::UnloadedError` を raise。無駄なクエリは出さない。 |
| `:log` | `Rails.logger.warn("[StrictLazy] ... read without preload (degraded to N+1)")` の後、1レコード解決。 |
| `:ignore` | 静かに1レコード解決 (N+1)。 |

設定方法:

- グローバル: `StrictLazy.violation = :log`
- Rails: `config.strict_lazy.violation = :log` (Railtie が初期化時に反映)
- Railtie の環境デフォルト: production → `:ignore`、それ以外 (development/test) → `:raise`

`:raise` の狙いは「開発中にプリロード忘れで即落として気づかせる」、`:ignore` の狙いは
「本番ではクラッシュさせず N+1 に退化させて動かし続ける」。

## ライフサイクルと内部 ivar

- `@_lazy_<reader>` — 解決済みの値。
- `@_batch_<reader>` — グループ共有の `Batch` 参照。
- `@_lazy_facade` — `.lazy` の `Facade` (メモ化)。

すべてレコードのインスタンス変数なので、**リクエストと共に GC** される。thread-local キャッシュも
ミドルウェアもグローバルなレジストリもない。`Batch` は値を各レコードの ivar に直接書くので
中間 Hash を持たず、レコードの hash 等価性にも依存しない (= **未保存レコードでも動く**)。

## 完全な実装例

```ruby
# app/models/post.rb
class Post < ApplicationRecord
  include StrictLazy

  # クロステーブル集計 (GROUP BY を1クエリに)
  lazy_load :comments_count, default: 0 do |posts, loader|
    by_id = posts.index_by(&:id)
    Comment.where(post_id: by_id.keys).group(:post_id).count.each do |post_id, n|
      loader.call(by_id[post_id], n)
    end
  end

  # 外部API (ID をまとめて bulk_fetch、即時解決)
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
  @posts = Post.recent         # ActiveRecord::Relation のままでよい（.to_a 不要）
  StrictLazy.preload(@posts)   # comments_count と avatar を準備
end
```

```erb
<%# app/views/posts/index.html.erb %>
<% @posts.each do |post| %>
  <span><%= post.lazy.comments_count %></span>
  <img src="<%= post.lazy.avatar %>">
<% end %>
```

プリロードを忘れて `post.lazy.comments_count` を読むと、development/test では
`StrictLazy::UnloadedError` が raise され、コントローラへの `StrictLazy.preload` 追加を促される。
