# rsyslog 設定ディレクトリ

## このディレクトリの役割

リポジトリ管理下の rsyslog 設定ファイルを置くディレクトリです。  
OS 上の実際の配置先（`/etc/rsyslog.d/`）へのコピーは、セットアップスクリプトが行います。

---

## ファイル一覧

| ファイル名 | 説明 |
|---|---|
| `10-syslog-appliance.conf` | UDP/TCP 514 でリモートログを受信し、送信元 IP・日付ごとに保存する drop-in 設定 |

---

## 配置先パス

```
/etc/rsyslog.d/10-syslog-appliance.conf
```

rsyslog は `/etc/rsyslog.d/` 配下の `*.conf` を数字順に読み込みます。  
`10-` というプレフィックスにより、デフォルト設定より後・他の追加設定より前に読み込まれます。

---

## 自動配置（推奨）

`scripts/setup-mvp0.sh` が以下を自動で行います。

1. 既存ファイルのバックアップ
2. 本ファイルを `/etc/rsyslog.d/` へコピー
3. SELinux コンテキストの設定
4. `rsyslogd -N1` による構文チェック
5. `systemctl restart rsyslog` による反映

```bash
sudo ./scripts/setup-mvp0.sh
```

---

## 手動配置

スクリプトを使わずに配置する場合のコマンド例です。  
**通常はスクリプトを使用してください。**

```bash
# リポジトリのルートから実行する想定
REPO_ROOT="$(pwd)"

# 既存ファイルをバックアップ（存在する場合）
if [[ -f /etc/rsyslog.d/10-syslog-appliance.conf ]]; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    sudo cp /etc/rsyslog.d/10-syslog-appliance.conf \
        "/var/log/syslog-appliance/.backup/10-syslog-appliance.conf.${TIMESTAMP}"
fi

# ファイルをコピー
sudo cp "${REPO_ROOT}/rsyslog/10-syslog-appliance.conf" \
    /etc/rsyslog.d/10-syslog-appliance.conf
sudo chown root:root /etc/rsyslog.d/10-syslog-appliance.conf
sudo chmod 0644 /etc/rsyslog.d/10-syslog-appliance.conf

# 構文チェック
sudo rsyslogd -N1

# 問題なければ再起動
sudo systemctl restart rsyslog
```

---

## 設定を変更する場合の注意点

設定を変更する際は、以下の手順を必ず守ってください。

### 1. バックアップを取る

```bash
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
sudo cp /etc/rsyslog.d/10-syslog-appliance.conf \
    "/etc/rsyslog.d/10-syslog-appliance.conf.${TIMESTAMP}.bak"
```

### 2. 構文チェックを実施する

変更後、rsyslog を再起動する前に構文チェックを行います。  
エラーが表示された場合は、rsyslog が起動できなくなるため **絶対に再起動しないでください**。

```bash
sudo rsyslogd -N1
```

正常な場合の出力例:
```
rsyslogd: version 8.2506.0, config validation run (level 1), master config /etc/rsyslog.conf
rsyslogd: End of config validation run. Bye.
```

### 3. rsyslog を再起動して反映する

```bash
sudo systemctl restart rsyslog
sudo systemctl status rsyslog
```

### 4. ログ受信を確認する

同一ホストから UDP でテストメッセージを送信して、ファイルが生成されるか確認します。

```bash
logger -n 127.0.0.1 -P 514 --udp "test message"
ls /var/log/syslog-appliance/raw/127.0.0.1/
```

詳細なテスト手順は [docs/08_mvp0_test.md](../docs/08_mvp0_test.md) を参照してください。
