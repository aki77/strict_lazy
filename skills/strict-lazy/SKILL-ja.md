---
name: strict-lazy
description: "preload/includes では表現できない「計算値」(外部API・ウィンドウ関数・クロステーブル集計) の N+1 を、明示プリロード必須＋dev/test で未プリロード読み取りを raise して潰す strict_lazy gem の使い方。使う: (1) 一覧の N+1 を直す依頼で原因が association でなく集計/外部API/計算メソッドのとき、(2) そうした値の事前読み込みを実装するとき。association で表現できる N+1 は対象外 (includes/preload/strict_loading を使う)。"
---

# strict_lazy

`strict_loading` を **計算値** に持ち込む gem。association で表現できない値をコントローラで明示プリロードさせ、未プリロード読み取りを dev/test で raise する。依存は `activesupport` のみ。

## まず適用可否を判断する

その値が `belongs_to`/`has_many` で表現できるなら strict_lazy ではなく標準解を使う。誤用すると無駄な複雑さが増える。

| N+1 の原因 | 使う道具 |
| --- | --- |
| association を辿る | `includes` / `preload` / `eager_load` |
| association の未ロード検出 | `strict_loading` / `bullet` |
| **association で表現できない計算値** | **strict_lazy** |

strict_lazy が向くのは preload で書けない値のみ:
- 外部API: `Svc.bulk_fetch(ids)` のようにまとめて引けるもの
- ウィンドウ関数・生SQL: `ROW_NUMBER() OVER (...)` など
- クロステーブル集計: `group(:post_id).count` など（`counter_cache` で済むならそちらを優先）

## 使い方（4点セット、欠けると動かない）

### 1. モデルで宣言

リゾルバは **ブロック** か **`from:`（クラスメソッド名）** の排他。どちらも `(records, loader)` を受け、解決できた各レコードで `loader.call(record, value)` を呼ぶ。**グループ全体に1回だけ走る**ので、ここで1クエリ/1API にまとめる。

```ruby
class Post < ApplicationRecord
  include StrictLazy

  lazy_load :comments_count, default: 0 do |posts, loader|
    by_id = posts.index_by(&:id)
    Comment.where(post_id: by_id.keys).group(:post_id).count.each do |post_id, n|
      loader.call(by_id[post_id], n)
    end
  end

  # from: は lazy_load より前に定義。FK 重複排除はリゾルバの責任（key: は無い）。
  def self.resolve_avatar(posts, loader)
    urls = AvatarService.bulk_fetch(posts.map(&:author_id).compact.uniq)
    posts.each { |p| loader.call(p, urls[p.author_id]) }
  end
  lazy_load :avatar, from: :resolve_avatar, sync: true
end
```

`loader.call` されなかったレコードには `default:` が入る（GROUP BY に出ない 0件 Post が `default: 0` になる仕組み）。

### 2. コントローラでプリロード

```ruby
@posts = Post.recent.to_a
StrictLazy.preload(@posts)             # 全ローダー。preload(@posts, :avatar) で一部のみ
```

ビューで読むコレクションと一致させる。`sync: false`（既定）は初回 `.lazy` 読みで一括解決＆メモ化、`sync: true` は preload 時点で即解決。

### 3. ビューで `.lazy.` 経由で読む

```erb
<%= post.lazy.comments_count %>
```

素のメソッドは生えない。必ず `.lazy.` を挟む。

### 4. プリロード忘れは raise

未プリロード読み取り時の `violation`: `:raise`（既定 dev/test、無駄クエリなし）/ `:log`（warn 後 1件解決）/ `:ignore`（既定 prod、静かに 1件解決＝N+1）。上書きは `StrictLazy.violation=` か `config.strict_lazy.violation`。

## 落とし穴

- `.lazy.` 付け忘れ → 普通のメソッド/カラムを読みプリロードが効かない
- `from:` を `lazy_load` より後に定義 → 宣言時に raise（ブロックは制約なし）
- リゾルバを1件ずつ書く → N+1 が消えない。`records` 全体を1回でまとめる
- `default: []` のような mutable 共有 → callable にする: `-> { [] }`（arity 0）/ `->(r) { ... }`（arity 1）。静的値はそのまま
- preload グループとビューのコレクションがずれる → 未プリロードのレコードが raise

詳細な引数・挙動は [references/api.md](references/api.md)。
