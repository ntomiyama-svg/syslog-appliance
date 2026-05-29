# syslog-appliance 運用手順

## Web UI アクセス（MVP 1.1 以降）

MVP 1.1 から nginx + HTTPS 構成に変更された。ブラウザでの管理画面アクセスは以下の通り。

- **URL**: `https://10.18.115.29/`（HTTP へのアクセスは自動的に HTTPS にリダイレクト）
- **認証**: ブラウザの Basic 認証ダイアログ（`/etc/syslog-appliance/backend.env` の `AUTH_USER` / `AUTH_PASS`）
- **証明書**: 自己署名証明書（ブラウザの警告は「詳細設定」→「接続を続ける」で許可）
- **API 直接アクセス**: `http://10.18.115.29:8080/` は廃止（FastAPI は 127.0.0.1 のみ）
- **詳細**: `docs/12_mvp1_frontend.md` を参照

---

## ログローテーション

### 設定

- 設定ファイル: `/etc/logrotate.d/syslog-appliance`
- 対象: `/var/log/syslog-appliance/raw/<送信元IP>/<日付>.log`
- 保持期間: 90 日（rotate 90）
- 圧縮: 1 日経過後に gzip 圧縮（delaycompress）
- 実行頻度: 毎日（daily、cron 経由）

### 手動実行（緊急時など）

```bash
sudo logrotate -f /etc/logrotate.d/syslog-appliance
```

### 動作確認（dry-run）

```bash
sudo logrotate -d /etc/logrotate.d/syslog-appliance
```

## ディスク使用量監視

### 仕組み

- systemd タイマー（`syslog-appliance-disk-check.timer`）が 5 分ごとに監視スクリプトを実行
- スクリプト本体: `/opt/syslog-appliance/scripts/check-disk-usage.sh`
- 監視対象: `/var/log` のマウントポイント
- 閾値: WARN 80%、CRITICAL 90%（`appliance.conf` の `[monitoring]` セクションで変更可能）
- システム起動から 1 分後に初回実行（`OnBootSec=1min`）
- 電源断中の実行予定はキャッチアップ実行（`Persistent=true`）

### 警告の出力先

1. **ログファイル**: `/var/log/syslog-appliance/alerts.log`（JSON Lines 形式）
   - WARN / CRITICAL 閾値超過時のみ追記
2. **メール送信**: `appliance.conf` で `mail_enabled=true` にして SMTP 設定を行う（MVP 1 以降で実装）
3. **通知ファイル**: `/var/lib/syslog-appliance/notifications/disk-usage.json`（Web UI 用）
   - 正常時も含め毎回最新1件で上書き

### 状態確認

```bash
sudo systemctl status syslog-appliance-disk-check.timer
sudo systemctl list-timers | grep disk-check
```

### 手動実行

```bash
sudo /opt/syslog-appliance/scripts/check-disk-usage.sh
```

### dry-run

```bash
sudo /opt/syslog-appliance/scripts/check-disk-usage.sh --dry-run
```

## 受信元制限の設定方法

### 概要

`/etc/syslog-appliance/appliance.conf` の `[receive]` セクションにある
`allowed_sources` を編集し、`apply-appliance-conf.sh` を実行することで
firewalld の受信元制限を動的に変更できます。

### 設定手順

1. 設定ファイルを編集する

```bash
sudo vi /etc/syslog-appliance/appliance.conf
```

```ini
[receive]
# 全許可（制限なし）の場合:
allowed_sources =

# 送信元を制限する場合（カンマ区切りで複数指定可能）:
allowed_sources = 192.168.1.0/24,10.0.0.0/8
```

2. 事前確認（dry-run）

```bash
sudo /opt/syslog-appliance/scripts/apply-appliance-conf.sh --dry-run
```

3. 設定を適用する

```bash
sudo /opt/syslog-appliance/scripts/apply-appliance-conf.sh
```

### 動作仕様

| `allowed_sources` の値 | firewalld の動作 |
|------------------------|-----------------|
| 空欄（デフォルト）      | ポート許可（全送信元から 514/udp, 514/tcp を受信） |
| CIDR 指定              | rich rule で指定 CIDR からのみ 514/udp, 514/tcp を許可（ポート許可は削除） |

### 注意事項

- `apply-appliance-conf.sh` は既存の 514 関連 rich rule をすべて削除してから再設定します。
- ロールバック（`rollback-mvp0.sh`）では rich rule は削除されません。必要な場合は手動で削除してください。
- `setup-mvp0.sh --allow-from` オプションでも初回設定時に受信元制限を設定できます。

---

## rsyslog 受信統計

### 概要

`impstats` モジュールにより、rsyslog の動作統計（受信メッセージ数、処理速度、キュー状態等）を
定期的にファイルに記録します。

### 出力先

- ファイル: `/var/log/syslog-appliance/stats/rsyslog-stats.log`
- 形式: JSON Lines（1 行 = 1 統計スナップショット）
- 記録間隔: 10 分ごと（interval=600）
- 保持期間: 30 日（logrotate により日次ローテーション）

### リアルタイム確認

```bash
sudo tail -f /var/log/syslog-appliance/stats/rsyslog-stats.log
```

### 設定ファイル

- リポジトリ: `rsyslog/11-syslog-appliance-stats.conf`
- 配置先: `/etc/rsyslog.d/11-syslog-appliance-stats.conf`
- 自動配置: `setup-mvp0.sh` の Step 13 で行われます

---

## rsyslog の自動回復（systemd 標準機能）

### 仕組み

- drop-in 設定: `/etc/systemd/system/rsyslog.service.d/restart.conf`
- rsyslog が異常終了した場合、systemd により 5 秒後に自動再起動
- 60 秒以内に 5 回失敗したらそれ以上の再起動を諦める（根本対応を促す）
- 自動配置: `setup-mvp0.sh` の Step 16 で行われます

### 動作確認

```bash
sudo systemctl show rsyslog | grep -E 'Restart=|RestartUSec=|StartLimit'
```

### 想定動作のテスト（注意：rsyslog を意図的に殺します）

```bash
sudo systemctl kill -s SIGKILL rsyslog
sleep 6
systemctl is-active rsyslog  # 自動再起動されて active になっているはず
```

---

## journald のディスク使用制限

### 現在の設定

- `/etc/systemd/journald.conf`
- `SystemMaxUse=500M`（最大使用量）
- `MaxRetentionSec=1month`（1 ヶ月で自動削除）

### TODO: journald の永続化

- 現状: 揮発モードで動作中（再起動でログ消失）
- 設定: `Storage=persistent` 設定済みだが反映されず
- 優先度: 低（MVP 1 以降、OS イメージ再構築時に再検証）
