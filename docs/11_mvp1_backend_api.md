# MVP 1.0 バックエンド API 仕様書

## 概要

| 項目 | 値 |
|------|----|
| ベース URL | `http://<appliance-ip>:8080` |
| 認証方式 | HTTP Basic 認証 |
| レスポンス形式 | JSON |
| 文字コード | UTF-8 |
| API バージョン | v1 |

## 認証

`/api/v1/*` 配下のすべてのエンドポイントに Basic 認証が必要。  
`/healthz` は認証不要。

```bash
# curl での認証例
curl -u admin:password http://localhost:8080/api/v1/devices
```

認証失敗時は `401 Unauthorized` を返す。

## 開発時のローカル起動

```bash
# 1. プロジェクトルートに移動
cd /home/devuser/projects/syslog-appliance

# 2. 仮想環境を作成してパッケージをインストール
python3 -m venv backend/venv
backend/venv/bin/pip install -r backend/requirements.txt

# 3. 環境変数を設定して起動
export SYSLOG_APPLIANCE_DB_PATH=/tmp/dev-syslog.sqlite
export SYSLOG_APPLIANCE_AUTH_USER=admin
export SYSLOG_APPLIANCE_AUTH_PASS=devpassword
export SYSLOG_APPLIANCE_LOG_LEVEL=DEBUG

cd backend
../venv/bin/uvicorn app.main:app --reload --port 8080

# Swagger UI: http://localhost:8080/docs
# ReDoc:       http://localhost:8080/redoc
```

---

## エンドポイント一覧

### ヘルスチェック

#### `GET /healthz`

認証不要。サービスが起動しているか確認する。

**リクエスト例:**
```bash
curl http://localhost:8080/healthz
```

**レスポンス例:**
```json
{
  "status": "ok",
  "version": "1.0.0"
}
```

---

### 機器管理 API

#### `GET /api/v1/devices` — 機器一覧取得

認証: 必要

| クエリパラメータ | 型 | 必須 | 説明 |
|------------------|----|------|------|
| `group_name` | string | 任意 | グループ名でフィルタ |

**リクエスト例:**
```bash
# 全件取得
curl -u admin:password http://localhost:8080/api/v1/devices

# グループ名でフィルタ
curl -u admin:password "http://localhost:8080/api/v1/devices?group_name=営業部"
```

**レスポンス例:**
```json
[
  {
    "id": 1,
    "ip": "192.168.1.10",
    "hostname": "sw-floor1",
    "device_name": "1Fフロアスイッチ",
    "group_name": "ネットワーク機器",
    "location": "1F サーバー室",
    "description": "Cisco Catalyst 2960",
    "created_at": "2026-05-29T10:00:00",
    "updated_at": "2026-05-29T10:00:00"
  }
]
```

---

#### `POST /api/v1/devices` — 機器登録

認証: 必要

| フィールド | 型 | 必須 | 説明 |
|------------|----|------|------|
| `ip` | string | **必須** | IP アドレス（IPv4/IPv6） |
| `hostname` | string | 任意 | ホスト名 |
| `device_name` | string | 任意 | 機器名（日本語可） |
| `group_name` | string | 任意 | グループ名 |
| `location` | string | 任意 | 設置場所 |
| `description` | string | 任意 | 備考 |

**リクエスト例:**
```bash
curl -u admin:password \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "ip": "192.168.1.10",
    "hostname": "sw-floor1",
    "device_name": "1Fフロアスイッチ",
    "group_name": "ネットワーク機器",
    "location": "1F サーバー室",
    "description": "Cisco Catalyst 2960"
  }' \
  http://localhost:8080/api/v1/devices
```

**レスポンス例（201 Created）:**
```json
{
  "id": 1,
  "ip": "192.168.1.10",
  "hostname": "sw-floor1",
  "device_name": "1Fフロアスイッチ",
  "group_name": "ネットワーク機器",
  "location": "1F サーバー室",
  "description": "Cisco Catalyst 2960",
  "created_at": "2026-05-29T10:00:00",
  "updated_at": "2026-05-29T10:00:00"
}
```

**エラー例（409 IP 重複）:**
```json
{
  "detail": "IP アドレス '192.168.1.10' は既に登録されています（ID: 1）。"
}
```

---

#### `GET /api/v1/devices/{device_id}` — 機器個別取得

認証: 必要

**リクエスト例:**
```bash
curl -u admin:password http://localhost:8080/api/v1/devices/1
```

**レスポンス例（200 OK）:**
```json
{
  "id": 1,
  "ip": "192.168.1.10",
  "hostname": "sw-floor1",
  "device_name": "1Fフロアスイッチ",
  "group_name": "ネットワーク機器",
  "location": "1F サーバー室",
  "description": "Cisco Catalyst 2960",
  "created_at": "2026-05-29T10:00:00",
  "updated_at": "2026-05-29T10:00:00"
}
```

**エラー例（404 Not Found）:**
```json
{
  "detail": "機器 ID 99 は存在しません。"
}
```

---

#### `PUT /api/v1/devices/{device_id}` — 機器更新

認証: 必要  
指定したフィールドのみ更新する。未指定のフィールドは変更されない。

**リクエスト例（設置場所と備考のみ更新）:**
```bash
curl -u admin:password \
  -X PUT \
  -H "Content-Type: application/json" \
  -d '{
    "location": "2F サーバー室",
    "description": "Cisco Catalyst 2960X（2026年更新）"
  }' \
  http://localhost:8080/api/v1/devices/1
```

**レスポンス例（200 OK）:**
```json
{
  "id": 1,
  "ip": "192.168.1.10",
  "hostname": "sw-floor1",
  "device_name": "1Fフロアスイッチ",
  "group_name": "ネットワーク機器",
  "location": "2F サーバー室",
  "description": "Cisco Catalyst 2960X（2026年更新）",
  "created_at": "2026-05-29T10:00:00",
  "updated_at": "2026-05-29T12:30:00"
}
```

---

#### `DELETE /api/v1/devices/{device_id}` — 機器削除

認証: 必要

**リクエスト例:**
```bash
curl -u admin:password \
  -X DELETE \
  http://localhost:8080/api/v1/devices/1
```

**レスポンス（204 No Content）:** レスポンスボディなし

**エラー例（404 Not Found）:**
```json
{
  "detail": "機器 ID 99 は存在しません。"
}
```

---

### システム情報 API

#### `GET /api/v1/system/info` — システム情報取得

認証: 必要

**リクエスト例:**
```bash
curl -u admin:password http://localhost:8080/api/v1/system/info
```

**レスポンス例:**
```json
{
  "app_name": "syslog-appliance-backend",
  "version": "1.0.0",
  "startup_time": "2026-05-29T10:00:00+00:00",
  "db_path": "/var/lib/syslog-appliance/db.sqlite",
  "config_path": "/etc/syslog-appliance/appliance.conf",
  "auth_user": "admin",
  "auth_pass_configured": true
}
```

---

#### `GET /api/v1/system/appliance-conf` — 設定ファイル参照

認証: 必要  
`/etc/syslog-appliance/appliance.conf` の内容を返す。  
機密情報（`password=` 等）が含まれる場合はマスクして返す。

**リクエスト例:**
```bash
curl -u admin:password http://localhost:8080/api/v1/system/appliance-conf
```

**レスポンス例:**
```json
{
  "path": "/etc/syslog-appliance/appliance.conf",
  "content": "# syslog-appliance 設定ファイル\nALLOWED_SENDERS=\"192.168.1.0/24\"\nMAX_DISK_USAGE_PERCENT=80\n",
  "line_count": 3
}
```

**エラー例（404 設定ファイルなし）:**
```json
{
  "detail": "設定ファイルが見つかりません: /etc/syslog-appliance/appliance.conf"
}
```

---

## エラーコード一覧

| HTTP ステータス | 状況 |
|-----------------|------|
| 400 Bad Request | リクエストのバリデーションエラー |
| 401 Unauthorized | 認証失敗（ユーザー名/パスワード不一致、または未設定） |
| 404 Not Found | 指定した ID のリソースが存在しない |
| 409 Conflict | IP アドレスが重複している |
| 422 Unprocessable Entity | 必須フィールドなし等の Pydantic バリデーションエラー |
| 500 Internal Server Error | 設定ファイルの権限エラー等 |

## Swagger UI

サービス起動後、ブラウザで以下にアクセスすると API を直接試せる。

```
http://<appliance-ip>:8080/docs
```

ReDoc（読みやすい仕様書形式）:
```
http://<appliance-ip>:8080/redoc
```
