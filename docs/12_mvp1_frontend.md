# MVP 1.1 設計書: nginx + HTTPS による本格 Web UI 構築

## 概要

MVP 1.0 で構築した FastAPI バックエンドに対して、nginx をリバースプロキシ兼静的ファイル
サーバーとして追加し、HTTPS 接続による管理 Web UI を提供する。

ブラウザからは HTTPS でアクセスし、FastAPI は外部に直接公開しない構成とする。

---

## アーキテクチャ

```
ブラウザ
  │
  │  HTTP :80
  ▼
[nginx]──────────────────────────────────────────────────
  │  301 リダイレクト → HTTPS :443
  ▼
[nginx :443 (TLS)]
  │
  ├─ /              → /opt/syslog-appliance/frontend/dist/ を静的配信
  ├─ /api/v1/*      → http://127.0.0.1:8080  リバースプロキシ
  ├─ /healthz       → http://127.0.0.1:8080/healthz
  ├─ /docs          → http://127.0.0.1:8080/docs (Swagger UI)
  └─ /openapi.json  → http://127.0.0.1:8080/openapi.json
                              │
                              ▼
                       [FastAPI :8080]
                       127.0.0.1 のみ listen
                              │
                              ▼
                           SQLite
```

---

## 採用技術と理由

| 技術 | 理由 |
|------|------|
| nginx | Rocky Linux の標準リポジトリで提供。軽量で設定がシンプル。静的配信とプロキシを 1 つで担える |
| Bootstrap 5 (CDN) | CDN から読み込むことでビルドステップ不要。業務アプリらしい見た目を素早く実現 |
| Vanilla JS + Fetch API | 依存ゼロ。Node.js/npm 環境が不要でアプライアンスに適している |
| 自己署名証明書 | 社内 LAN 利用想定のため。Let's Encrypt は後続フェーズ（MVP 2）で対応 |
| Basic 認証 (FastAPI) | MVP 1.1 では十分。セッション管理・JWT は MVP 1.2 以降で対応 |

---

## ディレクトリ構成

```
syslog-appliance/
├─ frontend/
│  ├─ dist/                          # nginx が配信するルートディレクトリ
│  │  ├─ index.html                  # シングルページ UI
│  │  ├─ css/app.css                 # 固有スタイル
│  │  └─ js/
│  │     ├─ api.js                   # API クライアント (window.api)
│  │     └─ devices.js               # 機器管理ロジック
│  └─ README.md
├─ nginx/
│  ├─ syslog-appliance.conf          # nginx サイト設定
│  └─ README.md
├─ scripts/
│  ├─ generate-self-signed-cert.sh   # 自己署名証明書生成
│  ├─ setup-mvp1-frontend.sh         # MVP 1.1 セットアップ
│  └─ rollback-mvp1-frontend.sh      # MVP 1.1 ロールバック
└─ systemd/
   └─ syslog-appliance-backend.service.d/
      └─ listen-localhost.conf        # ExecStart オーバーライド
```

---

## 自己署名証明書の扱い

### 証明書の仕様

| 項目 | 値 |
|------|----|
| 鍵長 | 2048bit RSA |
| 署名アルゴリズム | SHA-256 |
| 有効期限 | 825 日（デフォルト） |
| SAN | `IP:10.18.115.29`, `DNS:syslog-appliance-dev` |
| 配置先 | `/etc/syslog-appliance/ssl/server.crt`, `server.key` |

### ブラウザの警告について

社内 LAN での運用を想定しているため、自己署名証明書を使用する。
ブラウザアクセス時に「接続は安全ではありません」という警告が表示されるが、
「詳細設定」→「接続を続ける（安全でない可能性があります）」を選択して
アクセスする。

**重要**: 公開インターネットに晒される環境では自己署名証明書を使わないこと。
Let's Encrypt 等の信頼された CA の証明書を使用すること（MVP 2 以降で対応予定）。

---

## nginx 設定のセキュリティ考慮

| 対策 | 設定 |
|------|------|
| HTTPS 強制 | HTTP(80) へのアクセスを 301 で HTTPS(443) にリダイレクト |
| 古い TLS 無効化 | `ssl_protocols TLSv1.2 TLSv1.3` のみ許可 |
| HSTS | `Strict-Transport-Security: max-age=31536000` |
| MIME スニッフィング防止 | `X-Content-Type-Options: nosniff` |
| クリックジャッキング防止 | `X-Frame-Options: SAMEORIGIN` |
| バックエンド直接アクセス防止 | FastAPI を `127.0.0.1:8080` に bind し、外部から到達不可にする |
| SELinux | `httpd_can_network_connect=on` で nginx → backend プロキシを許可 |

---

## セットアップ手順

### 前提条件

- MVP 1.0（`setup-mvp1-backend.sh`）が完了していること
- `syslog-appliance` ユーザーおよび `/opt/syslog-appliance/` が存在すること

### 1. dry-run で確認

```bash
sudo bash scripts/setup-mvp1-frontend.sh --dry-run
```

### 2. 本番実行

```bash
sudo bash scripts/setup-mvp1-frontend.sh
```

### 3. ブラウザでアクセス

```
https://10.18.115.29/
```

自己署名証明書の警告が出たら「詳細設定」→「接続を続ける」を選択。
Basic 認証ダイアログが出たら `backend.env` の `AUTH_USER` / `AUTH_PASS` を入力。

---

## 動作確認手順

```bash
# nginx の状態確認
sudo systemctl status nginx.service

# バックエンドの状態確認（127.0.0.1 に bind されているか）
sudo ss -tlnp | grep ':8080'
# → 127.0.0.1:8080 のみ表示されること（0.0.0.0 は不可）

# ヘルスチェック（nginx 経由）
curl -k https://localhost/healthz

# ヘルスチェック（バックエンド直接 - localhost のみ到達可）
curl http://127.0.0.1:8080/healthz

# 機器一覧（認証あり）
curl -k -u admin:PASSWORD https://localhost/api/v1/devices

# 外部からの直接アクセスが拒否されることを確認（別ホストから）
curl http://10.18.115.29:8080/healthz  # → 接続拒否されること
```

---

## トラブルシューティング

### nginx が起動しない

```bash
# エラーログを確認
sudo journalctl -u nginx.service -n 50
sudo nginx -t  # 設定ファイルの構文チェック

# よくある原因:
# - default.conf とのポート競合 → /etc/nginx/conf.d/default.conf を退避
# - 証明書ファイルが存在しない → generate-self-signed-cert.sh を実行
# - SELinux の拒否 → sudo ausearch -m avc -ts recent で確認
```

### バックエンドへの接続が拒否される（502 Bad Gateway）

```bash
# バックエンドの状態確認
sudo systemctl status syslog-appliance-backend.service
sudo journalctl -u syslog-appliance-backend.service -n 30

# SELinux の確認
sudo getsebool httpd_can_network_connect
# → off の場合: sudo setsebool -P httpd_can_network_connect 1
```

### 証明書の警告を常に出さないようにしたい

社内 CA で署名した証明書をデプロイするか、
各クライアントの OS / ブラウザに自己署名証明書を信頼 CA として登録する。

---

## ロールバック手順

```bash
sudo bash scripts/rollback-mvp1-frontend.sh

# 証明書も削除する場合:
sudo bash scripts/rollback-mvp1-frontend.sh --purge-cert
```

ロールバック後は MVP 1.0 の状態（バックエンドが `0.0.0.0:8080` で直接公開）に戻る。

---

## 後続フェーズの予定

| フェーズ | 内容 |
|----------|------|
| MVP 1.2 | ログ閲覧画面、設定変更画面、セッション認証（JWT / Cookie）|
| MVP 2.0 | Let's Encrypt 証明書、メール通知、外部 syslog 転送設定 |
| MVP 3.0 | 物理アプライアンス化、HA 構成 |
