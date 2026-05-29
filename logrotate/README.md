# logrotate ディレクトリ

## このディレクトリの役割

syslog-appliance が受信したリモートログ用の logrotate 設定ファイルを管理します。

## ファイル一覧

| ファイル | 配置先 | 説明 |
|---|---|---|
| `syslog-appliance` | `/etc/logrotate.d/syslog-appliance` | ログローテーション設定本体 |

## 配置先

```
/etc/logrotate.d/syslog-appliance
```

Rocky Linux 9 では `/etc/logrotate.d/` に置いたファイルは `logrotate` の実行時（通常は `cron.daily`）に自動で読み込まれます。

## 自動配置（推奨）

`scripts/setup-mvp0.sh` を実行すると、この設定ファイルが自動的に配置されます。

```bash
sudo ./scripts/setup-mvp0.sh
```

## 手動配置

```bash
sudo cp logrotate/syslog-appliance /etc/logrotate.d/syslog-appliance
sudo chown root:root /etc/logrotate.d/syslog-appliance
sudo chmod 0644 /etc/logrotate.d/syslog-appliance
```

## 動作テスト（dry-run）

設定ファイルの構文チェックと動作確認は以下のコマンドで行います。
実際のローテーションは発生しません。

```bash
sudo logrotate -d /etc/logrotate.d/syslog-appliance
```

## 強制実行

通常のスケジュールを無視してローテーションを即時実行する場合:

```bash
sudo logrotate -f /etc/logrotate.d/syslog-appliance
```

> **注意:** `-f` は強制実行です。本番環境での実行は慎重に行ってください。
