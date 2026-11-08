# Omeka S + IIIF on Podman

Omeka S（IIIF Server などのモジュール入り）と MariaDB、必要に応じて IIPImage を
コンテナで動かすための構成です。

- テスト環境: `podman compose up -d`
- 本番環境: Podman Quadlet（systemd 管理）
- 初回起動時に Omeka S のインストールとモジュールの有効化まで自動で行います
- 前段にホストの Caddy を置く前提です（コンテナのポートは 127.0.0.1 にのみ公開）

```
Caddy（ホスト）
 ├─ /            → 127.0.0.1:8001  Omeka S（IIIF マニフェストは /iiif/3/<id>/manifest）
 ├─ /iiif-img/*  → 静的 IIIF タイル（任意, ②）
 └─ /iiif-ptif/* → 127.0.0.1:8002  IIPImage（任意, ③）
```

## 構成

| パス | 内容 |
|---|---|
| `compose.yaml` | db（MariaDB）/ omeka / iipsrv（profile `iiif`） |
| `.env.sample` | バージョン・ポート・パスワード・メモリ設定 |
| `config/test/`, `config/prod/` | サーバーごとの MariaDB / PHP 設定 |
| `omeka/Dockerfile` | PHP + Omeka S + モジュール |
| `omeka/modules.txt` | 同梱するモジュールとバージョン |
| `omeka/init/omeka-setup.php` | 自動インストール・マイグレーション・モジュール有効化 |
| `deploy/quadlet/` | 本番用 Quadlet ユニットのテンプレート |
| `deploy/install-quadlet.sh` | `.env` からユニットを生成してサービスを起動 |
| `deploy/Caddyfile.sample` | Caddy の設定例（basic_auth・タイル配信） |
| `scripts/make-tiles.sh` | vips で静的タイル / ピラミッド TIFF を作成 |

## テスト環境（podman compose）

```sh
git clone git@github.com:dfukagaw28/docker-omeka-s.git
cd docker-omeka-s
cp .env.sample .env
chmod 600 .env
vi .env          # DB_PASSWORD, OMEKA_ADMIN_* など

systemctl --user enable --now podman.socket   # podman compose（docker-compose 経由）に必要
podman compose up -d
podman compose logs -f omeka                  # [omeka-setup] のログで進捗を確認
```

`http://127.0.0.1:8001/` で Omeka S が開き、`.env` の `OMEKA_ADMIN_EMAIL` /
`OMEKA_ADMIN_PASSWORD` でログインできます（管理者情報が使われるのは初回のみ）。

IIPImage も動かす場合:

```sh
podman compose --profile iiif up -d
```

## 本番環境（Quadlet）

```sh
cp .env.sample .env && chmod 600 .env
vi .env          # CONFIG_DIR=./config/prod, パスワード, ENABLE_IIPSRV など
vi config/prod/mariadb.cnf config/prod/php.ini   # メモリ量に合わせる

deploy/install-quadlet.sh                 # イメージをビルドし、ユニットを生成して起動
sudo loginctl enable-linger "$USER"       # ログインしていなくても起動時に立ち上げる
journalctl --user -u omeka.service -f
```

- ユニットは `~/.config/containers/systemd/` に生成されます（`--system` を付けると
  root で `/etc/containers/systemd/`）。DB パスワードを含むので権限は 600 です。
- `.env` を変えたりバージョンを上げたりしたら、`deploy/install-quadlet.sh` を再実行します。
- `--dry-run DIR` で、生成されるユニットだけを確認できます。
- compose とはボリューム名が異なります（`<COMPOSE_PROJECT_NAME>-db-data`, `-files`）。

## Caddy

`deploy/Caddyfile.sample` を参考に設定します。Omeka S は `X-Forwarded-Proto` を見て
https の URL を生成するので、IIIF マニフェストの URL も https になります。

**公開範囲に注意:** Omeka でアイテムを非公開にしても、`/files/` 以下の画像や
IIIF 画像の URL は、URL が分かれば誰でも取得できます。公開してよいと確認できるまでは、
サイト全体に `basic_auth`（または IP 制限）をかけてください（サンプルに記載）。

**IIIF マニフェストのキャッシュ:** IiifServer モジュールはマニフェストを
`files/iiif/` にキャッシュします。最初のアクセス時の URL（ホスト名・スキーム）が
保存されるので、公開ドメインを変えたときや、Caddy を通さずにアクセスしてしまったときは
このディレクトリを削除してください。

```sh
podman compose exec omeka sh -c 'rm -rf /var/www/html/files/iiif/*'
```

## IIIF 画像の配信方式

1. **画像サーバーなし（既定）**: IIIF Server が Omeka の画像（original / large）を
   そのままマニフェストに載せます。large の長辺は `OMEKA_THUMB_LARGE`（既定 1600px）。
2. **静的タイル（IIIF Level 0）**: 手元で変換し、Caddy から静的に配信します。
   ```sh
   scripts/make-tiles.sh static https://omeka.example.org/iiif-img ./tiles image.tif
   # → tiles/image/info.json を /srv/iiif-img/ に置き、
   #   Omeka で「IIIF image」メディアとして https://omeka.example.org/iiif-img/image/info.json を登録
   ```
3. **IIPImage**（[`ghcr.io/dfukagaw28/iipsrv`](https://github.com/dfukagaw28/docker-iipsrv)）:
   ピラミッド TIFF を `IIIF_IMAGE_DIR` に置きます。コンテナ内では www-data（uid 33）が読むので、
   ファイルは誰でも読める権限（644、ディレクトリは 755）にしてください（`make-tiles.sh` はそうします）。
   ```sh
   scripts/make-tiles.sh ptif ./data/ptif image.tif
   # → https://omeka.example.org/iiif-ptif/image.tif/info.json
   ```
   `.env` の `IIPSRV_BASE_URL` に公開 URL（例: `https://omeka.example.org/iiif-ptif/`）を設定すると、
   `info.json` の `id` がその URL になります。

## メモリの少ないサーバー（1GB 程度）

- `CONFIG_DIR=./config/test` で MariaDB のバッファと PHP のメモリを小さくしています。
- Omeka はアップロード時に ImageMagick で縮小画像を作ります。大きな TIFF は
  メモリ不足の原因になるので、`MAGICK_MEMORY_LIMIT` / `MAGICK_MAP_LIMIT` で上限を
  かけています。原画は手元で縮小してからアップロードするのが安全です。

## バージョンの更新

- Omeka S / PHP / MariaDB: `.env` の `*_VERSION`
- モジュール: `omeka/modules.txt`（Daniel-KM 氏以外のモジュールは URL を書く）

更新後に再ビルドして起動すると、コアの DB マイグレーションとモジュールのアップグレードが
自動で実行されます（`podman compose up -d --build` または `deploy/install-quadlet.sh`）。
管理画面で無効化したモジュールは、自動で有効に戻しません。

## データのバックアップ

```sh
# DB
podman compose exec db sh -c 'mariadb-dump -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' > omeka.sql
# アップロードファイル
podman volume export omeka-s_omeka-files > omeka-files.tar
```
