# ナギソDCG（Godot 4.6 版）

このリポジトリの HTML/Vue 版（`index.html`）を Godot 4.6 に移植したもの。unityroom に投稿できる Web ビルド設定済み。

## カードの追加・調整（index.html を編集するだけで OK）

カードデータは **`index.html` が唯一の正**。Godot 版はビルドのたびに `index.html` から自動で取り込むので、Godot を触る必要はない。

1. いつもどおり `index.html` の `cardPool` にカードを追加・修正する（画像は `images/` に置く）
2. main にマージ（push）すると GitHub Actions の「Godot 版ビルド」が自動で走る
3. 終わったら次の URL から最新の `index.pck` をダウンロードして、unityroom のゲーム投稿画面からアップロード
   - `https://github.com/<このリポジトリ>/releases/download/godot-latest/index.pck`
   - （リポジトリのトップ右側の「Releases」→「godot-latest」からでも取れる）

プルリクエストの段階でもビルドとテストが走るので、マージ前に壊れていないか分かる（その回の `index.pck` は Actions の実行結果ページの「Artifacts」から取れる）。

取り込まれるもの:

| index.html | Godot 版 |
| --- | --- |
| `const cardPool = [...]` | `data/cards.json` |
| `abilityDictionary: [...]` | `data/abilities.json`（能力一覧） |
| プリセットデッキ（agro / ramp / combo）・CPU のカードプール（`cPool`） | `data/decks.json` |
| `images/` の画像 | `images/` |

注意:

- **新しい種類の能力**（`type` が新しいもの）は、ルール処理を `scripts/game.gd` にも書く必要がある。未実装の能力があるとビルドに警告が出る（カード自体は追加されるが、その能力は発動しない）
- 既存の能力の組み合わせ・数値変更・新しいカードの追加だけなら、index.html の編集だけで反映される
- cardPool の書式が壊れている（括弧の閉じ忘れ、`cost` が数値でない、デッキの番号がカード枚数を超える等）とビルドはエラーで止まり、原因が表示される
- ビルドでは CPU 戦を 60 試合自動で回すテストもしていて、スクリプトエラーが出たら失敗する

## 手元でビルドする場合

`data/` と `images/` は生成物なので git には入っていない。Godot で開く前に一度変換する（Node.js が必要）:

```bash
node godot/tools/sync_from_html.mjs
```

あとは Godot 4.6.2 で `godot/` フォルダを開き、「プロジェクト → エクスポート」で **Web** プリセットを選んで「プロジェクトのエクスポート」。
（設定済み: Thread Support オフ / Extension Support オフ。unityroom は Thread Support 非対応）
出力された `build/web/index.pck` を unityroom にアップロードする。画面サイズの設定がある場合は **1280 × 720**。

コマンドラインでも書き出せる（`godot/` フォルダで）:

```bash
Godot_v4.6.2-stable_win64_console.exe --headless --path . --export-release "Web" build/web/index.html
```

## スマホ・縦画面

画面が縦長なら基準解像度を 540×960 に切り替え、本家 index.html の `@media (max-width: 768px)` と同じく 1 カラムで表示する（横長なら 1280×720 の 2 カラム）。向きが変わると UI を組み直す。デッキ編集中の内容は引き継がれる。

- タイトル: 本家と同じ並び（ユーザー名 → モード → ルーム名 → カスタムデッキ → プリセットデッキ）。ページ全体をスクロールできる
- 対戦: ステータス → 手札（横スクロール）→ ログ → [能力一覧][ターン終了]。本家のスマホ表示は下が切れることがあるので、1 画面に収まるようにしている
- 能力一覧: 本家と同じく 1 列
- タップは指を離した位置で判定するので、手札をスクロールしてもカードを誤って使わない
- Web エクスポートで仮想キーボードを有効化（スマホでユーザー名やルーム名を入力できる）

## 構成

| ファイル | 内容 |
| --- | --- |
| `scripts/game.gd` | ゲーム状態とルール（元の Vue の data / methods / watch を移植） |
| `scripts/main.gd` | 画面（タイトル / デッキ編集 / 対戦）とオーバーレイをコードで構築 |
| `scripts/socket_io.gd` | 最小の Socket.IO v4 クライアント（WebSocket 上で手実装） |
| `tools/sync_from_html.mjs` | `index.html` からカード・能力・デッキ・画像を取り込む変換スクリプト |
| `data/*.json` | 変換スクリプトの出力（カードプール / 能力用語一覧 / プリセットデッキ）。git 管理外 |
| `fonts/NotoSansJP-Regular.otf` | 日本語フォント（SIL OFL、`fonts/OFL.txt`）。Web では OS フォントが使えないため同梱 |
| `tests/` | 自動テスト（エクスポートには含まれない） |

## オンライン対戦

既存の Node.js サーバー（`https://nagisworddcg-0.onrender.com/`）にそのまま接続する。
送受信するイベントとデータ形式は HTML 版と同じなので、**HTML 版のプレイヤーと Godot 版のプレイヤーで対戦・観戦できる**。
サーバー側の変更は不要。

接続先を変えるときは `scripts/game.gd` の `SERVER_URL`、または開発時は起動引数で:

```bash
Godot_v4.6.2-stable_win64_console.exe --path . -- --server=http://localhost:3000
```

Render の無料プランはしばらくアクセスがないと休止するので、最初のマッチングに 1 分ほどかかることがある（待機画面にも表示している）。

## 元の HTML 版からの変更点

- 絵文字は同梱フォントに無いため記号（★ ◆ ● など）に置き換えて表示。HTML 版から届くログの絵文字も同様に変換
- セーブは localStorage の代わりに `user://nagiso_save.json`（Web ではブラウザの IndexedDB に保存される）。HTML 版のデッキは引き継がれない
- 以下の不具合を修正
  - CPU の【機巧増幅】がトークンではなく `cardPool[86〜88]`（終焉のナギソ等）を山札に入れていた → カード名で指定
  - オンラインで【陰陽】を使うと、生成カードの乱数を自分の処理で消費してから送っていたため相手側で再現できなかった → 消費前のコピーを送信
  - 観戦時、マッチング待機画面が閉じなかった / 相手のターン終了を受けると観戦者側で LO 敗北処理が走っていた
  - 「パン屋さん」の空の付与能力で `undefined` 能力が付いていた

## テスト

```bash
# CPU 戦を 60 試合自動で回す（全カードを含むランダムデッキ込み）。先に tools/sync_from_html.mjs を実行しておく
Godot_v4.6.2-stable_win64_console.exe --headless --path . -s tests/sim.gd

# オンライン対戦（ローカルで server.js を起動しておく）
Godot_v4.6.2-stable_win64_console.exe --headless --path . -s tests/online.gd -- --server=http://localhost:3000
```
