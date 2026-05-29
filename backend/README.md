# syslog-appliance Backend

syslog アプライアンスの管理 REST API。FastAPI + SQLite で構成する MVP 1.0 バックエンド。

## 役割

- 機器管理（登録・参照・更新・削除）の REST API を提供する
- `appliance.conf` の内容を API 経由で参照できる
- Basic 認証で保護し、社内 LAN からのみアクセスを受け付ける

## 起動方法

### 開発時（uvicorn を直接起動）

```bash
# リポジトリルートから実行
cd /home/devuser/projects/syslog-appliance

# 仮想環境を作成してパッケージをインストール
python3 -m venv backend/venv
backend/venv/bin/pip install -r backend/requirements.txt

# 環境変数を設定
export SYSLOG_APPLIANCE_DB_PATH=/tmp/dev-syslog.sqlite
export SYSLOG_APPLIANCE_AUTH_USER=admin
export SYSLOG_APPLIANCE_AUTH_PASS=devpassword

# 起動（--reload でコード変更を自動検知）
cd backend
../venv/bin/uvicorn app.main:app --reload --port 8080
```

Swagger UI: http://localhost:8080/docs

### 本番（systemd で常駐起動）

```bash
# セットアップ（初回のみ）
sudo bash scripts/setup-mvp1-backend.sh

# パスワードを設定
sudo vi /etc/syslog-appliance/backend.env

# 起動
sudo systemctl start syslog-appliance-backend
sudo systemctl status syslog-appliance-backend
```

## 環境変数一覧

| 変数名 | デフォルト | 説明 |
|--------|-----------|------|
| `SYSLOG_APPLIANCE_DB_PATH` | `/var/lib/syslog-appliance/db.sqlite` | SQLite DB ファイルのパス |
| `SYSLOG_APPLIANCE_CONFIG_PATH` | `/etc/syslog-appliance/appliance.conf` | appliance.conf のパス |
| `SYSLOG_APPLIANCE_AUTH_USER` | `admin` | Basic 認証ユーザー名 |
| `SYSLOG_APPLIANCE_AUTH_PASS` | （なし） | Basic 認証パスワード（**必ず設定すること**） |
| `SYSLOG_APPLIANCE_LOG_LEVEL` | `INFO` | ログレベル（DEBUG/INFO/WARNING/ERROR） |

## API ドキュメント

詳細は [docs/11_mvp1_backend_api.md](../docs/11_mvp1_backend_api.md) を参照。

起動後は Swagger UI で対話的に確認できる:

```
http://<appliance-ip>:8080/docs
```

## ヘルスチェック

```bash
curl http://localhost:8080/healthz
# {"status":"ok","version":"1.0.0"}
```
