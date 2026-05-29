# syslog-appliance 運用手順

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

## journald のディスク使用制限

### 現在の設定

- `/etc/systemd/journald.conf`
- `SystemMaxUse=500M`（最大使用量）
- `MaxRetentionSec=1month`（1 ヶ月で自動削除）

### TODO: journald の永続化

- 現状: 揮発モードで動作中（再起動でログ消失）
- 設定: `Storage=persistent` 設定済みだが反映されず
- 優先度: 低（MVP 1 以降、OS イメージ再構築時に再検証）
