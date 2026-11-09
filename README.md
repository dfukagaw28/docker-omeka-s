# Omeka S + IIIF on Podman

Omeka S（IIIF Server などのモジュール入り）と MariaDB、必要に応じて IIPImage を
コンテナで動かすための構成です。

- 手元で試す: `podman compose up -d`
- サーバー（テスト・本番）: Podman Quadlet（systemd 管理）
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

## 手元で試す（podman compose）

`podman compose` は、compose の本体（`docker-compose` または `podman-compose`）を
呼び出すだけのコマンドなので、どちらかを別に入れておく必要があります。
入っていないと `Error: looking up compose provider failed` になります。

- **docker-compose**（動作確認済み）: Docker Compose v2 のバイナリを入れ、Podman の
  ソケットを有効にします（下の `systemctl --user enable --now podman.socket`）。
- **podman-compose**: `sudo apt install podman-compose`。ソケットは不要です。
  ただし、この構成での動作はまだ確認していません。

サーバーでは compose ではなく、下の「サーバーへのデプロイ（Quadlet）」を使ってください
（compose の本体は不要です）。

```sh
git clone git@github.com:dfukagaw28/docker-omeka-s.git
cd docker-omeka-s
cp .env.sample .env
chmod 600 .env
vi .env          # DB_PASSWORD, OMEKA_ADMIN_* など

systemctl --user enable --now podman.socket   # docker-compose を使う場合のみ必要
podman compose up -d
podman compose logs -f omeka                  # [omeka-setup] のログで進捗を確認
```

`http://127.0.0.1:8001/` で Omeka S が開き、`.env` の `OMEKA_ADMIN_EMAIL` /
`OMEKA_ADMIN_PASSWORD` でログインできます（管理者情報が使われるのは初回のみ）。

IIPImage も動かす場合:

```sh
podman compose --profile iiif up -d
```

## サーバーへのデプロイ（Quadlet）

テストサーバーも本番サーバーも同じ手順で、違いは `.env` の `CONFIG_DIR` だけです
（テスト: `./config/test`、本番: `./config/prod`）。
以下は Ubuntu 26.04 LTS + Podman 5.7 での例です。サービスは一般ユーザー（rootless）で動かします。

### 1. 準備（初回のみ）

```sh
sudo apt install podman git gettext-base caddy
podman --version    # 5.x
```

`caddy` が Ubuntu のリポジトリにない・古い場合は、Caddy 公式の apt リポジトリから入れます。

rootless の Podman が動くことを確認します（Ubuntu は AppArmor で一般ユーザーの
名前空間作成を制限していますが、apt で入れた Podman は許可されています）。

```sh
grep "^$USER:" /etc/subuid /etc/subgid                # 両方に行があること
podman info --format '{{.Host.Security.Rootless}}'    # true
podman run --rm docker.io/library/alpine echo ok
```

`/etc/subuid` / `/etc/subgid` に行がなければ追加します。

```sh
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
```

メモリが 1GB 程度のサーバーでは swap を用意します（イメージのビルド時に PHP 拡張を
コンパイルするため）。

```sh
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

ログインしていなくても、サーバー起動時にサービスが立ち上がるようにします。

```sh
sudo loginctl enable-linger "$USER"
```

ufw を有効にしている場合は 80 / 443 を開けます（コンテナのポートは 127.0.0.1 にしか
公開しないので、それ以外は不要です）。

```sh
sudo ufw allow 80,443/tcp
```

### 2. 取得と設定

```sh
git clone https://github.com/dfukagaw28/docker-omeka-s.git ~/omeka-s
cd ~/omeka-s
cp .env.sample .env && chmod 600 .env
vi .env
```

`.env` で設定する項目:

- `CONFIG_DIR`: テストサーバーは `./config/test`、本番は `./config/prod`
  （本番は `config/prod/mariadb.cnf` と `config/prod/php.ini` をメモリ量に合わせる）
- `DB_PASSWORD`, `OMEKA_ADMIN_PASSWORD`: 英数字と `. _ @ + -` のみ
- `OMEKA_ADMIN_EMAIL`, `OMEKA_TITLE`
- IIPImage を使う場合: `ENABLE_IIPSRV=true`, `IIPSRV_BASE_URL=https://<ドメイン>/iiif-ptif/`

### 3. デプロイ

```sh
deploy/install-quadlet.sh                 # イメージをビルドし、ユニットを生成して起動
journalctl --user -u omeka.service -f     # 進捗を確認
```

ログに `[omeka-setup] Installed module BulkImport ...` まで出れば完了です。
初回はイメージのビルドがあるため、1GB のサーバーでは十数分かかることがあります。

`systemctl --user` / `journalctl --user` は、SSH でそのユーザーとして直接ログインしたときに
使えます（`sudo su -` などで切り替えた場合は使えません）。

### 4. Caddy

`deploy/Caddyfile.sample` を `/etc/caddy/Caddyfile` にコピーし、ドメイン名と
`basic_auth` のパスワードハッシュ（`caddy hash-password` で作成）を書き換えます。
静的タイル（`/iiif-img/`）を使わない場合は、その部分を削除して構いません。

```sh
sudo systemctl reload caddy
```

詳しくは下の「Caddy」の節を参照してください。

### 5. 確認

- `https://<ドメイン>/login` で管理者としてログインできる
- アイテムを作って画像を登録し、`https://<ドメイン>/iiif/3/<id>/manifest` の URL が https になっている
- サーバーを再起動しても `systemctl --user status omeka.service` が active になる

**最初のアクセスは必ず Caddy 経由で行ってください。** IiifServer は最初にアクセスされた
ときの URL でマニフェストをキャッシュします（下の「Caddy」の節を参照）。

### 更新

```sh
cd ~/omeka-s && git pull && deploy/install-quadlet.sh
```

DB のマイグレーションとモジュールのアップグレードは起動時に自動で実行されます。

### 補足

- ユニットは `~/.config/containers/systemd/` に生成されます（`--system` を付けると
  root で `/etc/containers/systemd/`）。DB パスワードを含むので権限は 600 です。
- `.env` を変えたりバージョンを上げたりしたら、`deploy/install-quadlet.sh` を再実行します。
- `--dry-run DIR` で、生成されるユニットだけを確認できます。
- compose とはボリューム名が異なります（`<COMPOSE_PROJECT_NAME>-db-data`, `-files`）。
- マウントに付けている `:z` は SELinux 用で、Ubuntu（AppArmor）では無視されます。

### ホストに MariaDB / MySQL が入っている場合（AppArmor）

ホストに `mariadb-server` などが入っていると、その AppArmor プロファイル（`mariadbd`）が
**コンテナ内の mariadbd にも適用されます**（AppArmor は実行ファイルのパスで割り当てるため）。
このプロファイルは Podman からのシグナルを受け付けないので、DB コンテナを止めるたびに
systemd が SIGKILL することになり、次の起動で crash recovery が走ります。

症状:

- DB のログに `Recovering after a crash using tc.log` が毎回出る
- `StopSignal SIGTERM failed to stop container ... resorting to SIGKILL`
- `podman kill --signal TERM <PREFIX>-db` が `Permission denied`
- `ps -eo pid,label,comm | grep mariadbd` で `mariadbd (enforce)` と表示される
  （正常なら `crun (unconfined)`）
- `sudo journalctl -k | grep 'apparmor="DENIED"'` に `profile="mariadbd" ... peer="crun"` が出る

対処（ホストの MariaDB を使っていない場合）:

```sh
sudo mariadb -e 'SHOW DATABASES;'                 # 他の用途がないか確認
sudo mariadb-dump --all-databases > ~/host-mariadb-backup.sql && chmod 600 ~/host-mariadb-backup.sql
sudo systemctl stop mariadb
sudo apt purge 'mariadb-server*' 'mariadb-client*' mariadb-common && sudo apt autoremove --purge
echo -n mariadbd | sudo tee /sys/kernel/security/apparmor/.remove   # 読み込み済みのプロファイルを外す
systemctl --user restart omeka-db.service omeka.service
```

ホストの MariaDB を使い続ける場合は、`/etc/apparmor.d/local/` 以下のローカル設定で
`signal (receive) peer=crun,` と `signal (receive) peer=podman,` を許可し、
`sudo apparmor_parser -r` でプロファイルを読み込み直します（この方法は未確認）。

## Caddy

`deploy/Caddyfile.sample` を参考に設定します。Omeka S は `X-Forwarded-Proto` を見て
https の URL を生成するので、IIIF マニフェストの URL も https になります。

**公開範囲に注意:** Omeka でアイテムを非公開にしても、`/files/` 以下の画像や
IIIF 画像の URL は、URL が分かれば誰でも取得できます。公開してよいと確認できるまでは、
サイト全体に `basic_auth`（または IP 制限）をかけてください（サンプルに記載）。

**Basic 認証:** サンプルでは `basic_auth` をサイトブロックの直下に置いているので、
Omeka・`/files/`・`/iiif-img/`・`/iiif-ptif/` のすべてにかかります。

```sh
caddy hash-password                  # パスワードを入力すると $2a$14$... が出力される
sudoedit /etc/caddy/Caddyfile        # viewer の後ろのハッシュを置き換える
caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

- ユーザーを増やすときは、`basic_auth { ... }` の中に `ユーザー名 ハッシュ` の行を足します。
- サンプルのハッシュ（`REPLACE_WITH_...`）のままでも `caddy validate` は通りますが、
  誰もログインできません。必ず置き換えてください。
- Omeka のログインとは別です。管理画面に入るには、両方を通ります。
- Omeka 内の Mirador など、同じサイト上のビューアは問題なく動きます
  （ブラウザが認証情報を自動で付けます）。
- 他サイトの IIIF ビューアからは読めません。ブラウザは CORS のプリフライト（OPTIONS）に
  認証情報を付けないため、401 になります。外部に公開する段階で `basic_auth` を外すか、
  IIIF 部分（`/iiif/*`, `/files/*`, `/iiif-img/*`, `/iiif-ptif/*`）を認証の対象外にします。
  対象外にした部分は、URL が分かれば誰でも取得できます。

**IIIF マニフェストのキャッシュ:** IiifServer モジュールはマニフェストを
`files/iiif/` にキャッシュします。最初のアクセス時の URL（ホスト名・スキーム）が
保存されるので、公開ドメインを変えたときや、Caddy を通さずにアクセスしてしまったときは
このディレクトリを削除してください。

```sh
podman exec omeka-s-app sh -c 'rm -rf /var/www/html/files/iiif/*'         # Quadlet
podman compose exec omeka sh -c 'rm -rf /var/www/html/files/iiif/*'      # compose
```

## IIIF 画像の配信方式

1. **画像サーバーなし（既定）**: IIIF Server が Omeka の画像（original / large）を
   そのままマニフェストに載せます。large の長辺は `OMEKA_THUMB_LARGE`（既定 1600px）。
   IIIF Server は既定ではマニフェストに画像サービス（`/iiif/3/<メディアID>`）を載せますが、
   画像サーバーがないとタイルの取得が 503 になり、ビューアに画像が表示されません。
   そのため初回インストール時に、モジュール設定の「Default IIIF image api version」を
   「No image server」にし、各バージョンの対応レベルを空にしています。
   この自動設定を入れる前にインストールした環境では、管理画面の「モジュール」→
   IIIF Server の設定 →「Image server」タブで同じように変え、マニフェストのキャッシュを削除してください。
   Mirador は公開サイトのアイテムページに表示されます（サイトの「テーマ」→
   リソースページの設定で、アイテムに Mirador ブロックを追加）。
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

サーバー（Quadlet）の場合（`COMPOSE_PROJECT_NAME` が既定の `omeka-s` のとき）:

```sh
# DB
podman exec omeka-s-db sh -c 'mariadb-dump -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' > omeka.sql
# アップロードファイル
podman volume export omeka-s-files > omeka-files.tar
```

手元（podman compose）の場合:

```sh
podman compose exec db sh -c 'mariadb-dump -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"' > omeka.sql
podman volume export omeka-s_omeka-files > omeka-files.tar
```
