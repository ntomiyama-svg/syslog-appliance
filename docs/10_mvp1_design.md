# MVP 1 全体設計

## MVP 1 の位置づけ

MVP 0（rsyslog 受信基盤）が完成した次のフェーズ。  
syslog アプライアンスに「Web 管理画面」を追加することを目標とする。  
3 つのサブフェーズに分けて段階的に実装する。

```
MVP 0  → rsyslog 受信・保存（完了）
MVP 1.0 → バックエンド基盤（本フェーズ）
MVP 1.1 → 設定書き込み API
MVP 1.2 → フロントエンド（HTML/JS）+ HTTPS
```

## サブフェーズ構成

| フェーズ | 内容 | 状態 |
|----------|------|------|
| MVP 1.0 | FastAPI バックエンド、機器管理 API、Basic 認証、SQLite | 実装済み |
| MVP 1.1 | 受信元制限の書き込み API（appliance.conf 更新） | 未実装 |
| MVP 1.2 | フロントエンド（HTML/JS）、Caddy で HTTPS 対応 | 未実装 |

## アーキテクチャ図

```
社内 LAN クライアント（ブラウザ/curl）
        │
        │ HTTP :8080（MVP 1.0〜1.1）
        │ HTTPS :443（MVP 1.2 以降）
        ↓
┌─────────────────────────────────────┐
│  FastAPI / uvicorn                  │
│  systemd: syslog-appliance-backend  │
│  User: syslog-appliance             │
├────────────────┬────────────────────┤
│                │                    │
↓                ↓                    ↓
SQLite       appliance.conf        （MVP 1.2）
/var/lib/    /etc/syslog-           静的ファイル
syslog-      appliance/             配信
appliance/   appliance.conf
db.sqlite
│
devices テーブル（機器情報）
```

## 技術選定の理由

### Python + FastAPI

- Rocky Linux 9 に Python 3.9 が標準搭載のため追加インストール不要
- FastAPI は自動 Swagger UI 生成、型安全、非同期対応と開発効率が高い
- Pydantic v2 によるバリデーションで入力値の安全性を確保

### SQLite

- 外部 DB サービス不要で、単一ファイルでデータを管理できる
- 機器管理（数百〜数千台規模）には性能として十分
- バックアップが `cp` 一発で完了する運用の容易さ
- 将来的に PostgreSQL への移行が必要になった場合も SQLAlchemy の抽象化で対応可能

### Basic 認証

- 実装・デバッグが容易（curl で即確認できる）
- 社内 LAN 限定での運用想定のため、Basic 認証で十分なセキュリティレベル
- HTTPS 化（MVP 1.2）後は盗聴リスクも排除できる
- `secrets.compare_digest` でタイミング攻撃対策済み

### uvicorn + systemd

- ASGI サーバーとして本番品質の uvicorn を採用
- systemd の `Restart=on-failure` で自動回復
- journald にログが自動集約される

## データベース設計

### devices テーブル

機器管理の中心テーブル。syslog を送信してくる機器の情報を管理する。

| カラム名 | 型 | 制約 | 説明 |
|----------|----|------|------|
| id | INTEGER | PK, AUTO | 主キー |
| ip | VARCHAR(45) | UNIQUE, NOT NULL | IP アドレス（IPv4/IPv6 対応） |
| hostname | VARCHAR(255) | NULL 可 | DNS ホスト名 |
| device_name | VARCHAR(255) | NULL 可 | 機器名（日本語可） |
| group_name | VARCHAR(100) | NULL 可 | グループ・部署名 |
| location | VARCHAR(255) | NULL 可 | 設置場所 |
| description | VARCHAR(1000) | NULL 可 | 備考 |
| created_at | DATETIME | NOT NULL | 作成日時（自動） |
| updated_at | DATETIME | NOT NULL | 更新日時（自動更新） |

**インデックス:**
- `ip`（UNIQUE インデックス）: IP による高速検索
- `group_name`（インデックス）: グループフィルタの高速化

**IP カラムが 45 文字な理由:**  
IPv6 のフルフォーマット（例: `2001:0db8:85a3:0000:0000:8a2e:0370:7334`）は最長 39 文字。  
IPv4-mapped IPv6 アドレス（例: `::ffff:192.168.1.1`）を考慮して余裕を持たせている。

## セキュリティ設計

### MVP 1.0 のセキュリティ方針

| 項目 | 対策 |
|------|------|
| 認証 | HTTP Basic 認証（Base64 エンコード） |
| 通信経路 | 社内 LAN のみ許可（firewalld で外部遮断） |
| パスワード保護 | `secrets.compare_digest` でタイミング攻撃対策 |
| 設定保護 | `backend.env` のパーミッション: `640 (root:syslog-appliance)` |
| プロセス分離 | 専用ユーザー `syslog-appliance`（ログインシェルなし） |
| SELinux | ポート 8080 を `http_port_t` に登録 |
| systemd 強化 | `NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=strict` |

### MVP 1.2 以降で対応する項目

- HTTPS（Caddy または nginx による TLS 終端）
- CORS の許可オリジンを LAN のドメインに限定
- パスワードのハッシュ化（bcrypt 等）
- ログイン試行の rate limiting

## ファイル配置（本番環境）

```
/opt/syslog-appliance/backend/      ← アプリケーション本体
    app/                            ← Python パッケージ
    venv/                           ← Python 仮想環境
    requirements.txt

/etc/syslog-appliance/
    backend.env                     ← 環境変数（パスワード含む、0640）
    appliance.conf                  ← rsyslog 設定（参照のみ）

/var/lib/syslog-appliance/
    db.sqlite                       ← SQLite DB（機器情報等）

/etc/systemd/system/
    syslog-appliance-backend.service
```

## MVP 1.1 の予定

- `PUT /api/v1/system/appliance-conf` エンドポイント追加
- appliance.conf の `ALLOWED_SENDERS` を API 経由で更新
- 更新後に `apply-appliance-conf.sh` を呼び出して rsyslog に反映
- 変更履歴を SQLite に保存（audit ログ）

## MVP 1.2 の予定

- フロントエンド（Vanilla JS または Vue.js）の実装
- 機器一覧・登録・編集・削除の Web UI
- ログ閲覧 API（`GET /api/v1/logs`）の追加
- Caddy によるリバースプロキシと HTTPS 対応
