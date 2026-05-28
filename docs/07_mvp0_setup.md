# MVP 0 セットアップ手順書

## 概要

本手順書は、syslog-appliance MVP 0 を Rocky Linux 9 上にセットアップするための手順を説明します。

MVP 0 では以下の機能を実現します。

- UDP/TCP ポート 514 でリモートデバイスからの Syslog を受信する
- 受信したログを `/var/log/syslog-appliance/raw/<送信元IP>/<YYYY-MM-DD>.log` に保存する
- ローカルシステムのログ（journald 経由）には影響を与えない

Web UI やログ検索機能は MVP 1 以降で実装します。

---

## 前提条件

| 項目 | 要件 |
|---|---|
| OS | Rocky Linux 9.x |
| rsyslog | 8.x（`rsyslog` パッケージ） |
| ファイアウォール | `firewalld` が稼働していること |
| SELinux | Enforcing または Permissive（Disabled でも動作するが非推奨） |
| 実行ユーザー | root または sudo 権限を持つユーザー |
| ネットワーク | UDP/TCP 514 が到達可能であること |

### 事前確認コマンド

```bash
# rsyslog がインストールされているか確認
rpm -q rsyslog

# firewalld が稼働しているか確認
systemctl status firewalld

# SELinux の状態確認
getenforce

# semanage コマンドの確認
which semanage || sudo dnf install -y policycoreutils-python-utils
```

---

## 自動セットアップ手順（setup-mvp0.sh を使う方法）

### 1. リポジトリをクローンまたは配置する

```bash
# 例: /opt/syslog-appliance に配置する場合
sudo git clone <リポジトリURL> /opt/syslog-appliance
cd /opt/syslog-appliance
```

### 2. dry-run で事前確認する

**必ず最初に dry-run を実施してください。**

```bash
sudo ./scripts/setup-mvp0.sh --dry-run
```

実際の変更は行われず、実行予定のコマンドが表示されます。内容を確認して問題がなければ次のステップに進んでください。

### 3. セットアップを実行する

#### 受信元制限なし（すべての送信元から受信）

```bash
sudo ./scripts/setup-mvp0.sh
```

#### 受信元を特定ネットワークに制限する

```bash
# 例: 192.168.1.0/24 からのみ受信
sudo ./scripts/setup-mvp0.sh --allow-from 192.168.1.0/24

# 例: 複数のネットワークに制限
sudo ./scripts/setup-mvp0.sh --allow-from 192.168.1.0/24,10.0.0.0/8
```

### 4. セットアップ結果を確認する

スクリプト終了後、以下のコマンドで動作を確認します。

```bash
# rsyslog が起動しているか確認
systemctl status rsyslog

# ポートがリッスンしているか確認
ss -ulnp | grep :514    # UDP
ss -tlnp | grep :514    # TCP

# firewalld の設定確認
firewall-cmd --list-all
```

---

## 手動セットアップ手順

スクリプトを使わずに手動でセットアップする場合の手順です。  
**通常はスクリプトを使用してください。**

### 1. ディレクトリの作成

```bash
# ログ保存ディレクトリ
sudo mkdir -p /var/log/syslog-appliance/raw
sudo chmod 0750 /var/log/syslog-appliance/raw
sudo chown root:root /var/log/syslog-appliance/raw

# バックアップディレクトリ
sudo mkdir -p /var/log/syslog-appliance/.backup
sudo chmod 0750 /var/log/syslog-appliance/.backup

# アプライアンス設定ディレクトリ
sudo mkdir -p /etc/syslog-appliance
sudo chmod 0750 /etc/syslog-appliance
sudo chown root:root /etc/syslog-appliance
```

### 2. rsyslog 設定ファイルの配置

```bash
# 既存ファイルのバックアップ（存在する場合）
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
if [[ -f /etc/rsyslog.d/10-syslog-appliance.conf ]]; then
    sudo cp /etc/rsyslog.d/10-syslog-appliance.conf \
        "/var/log/syslog-appliance/.backup/10-syslog-appliance.conf.${TIMESTAMP}"
fi

# ファイルのコピー（リポジトリのルートディレクトリで実行）
sudo cp rsyslog/10-syslog-appliance.conf /etc/rsyslog.d/
sudo chown root:root /etc/rsyslog.d/10-syslog-appliance.conf
sudo chmod 0644 /etc/rsyslog.d/10-syslog-appliance.conf
```

### 3. 設定雛形ファイルのコピー

```bash
sudo cp etc/syslog-appliance/appliance.conf.example /etc/syslog-appliance/
sudo cp etc/syslog-appliance/devices.yaml.example /etc/syslog-appliance/
sudo chown root:root /etc/syslog-appliance/*.example
sudo chmod 0644 /etc/syslog-appliance/*.example
```

### 4. SELinux の設定

```bash
# TCP 514 を syslogd_port_t に登録（既に登録済みの場合はエラーになるが無視してよい）
sudo semanage port -a -t syslogd_port_t -p tcp 514

# SELinux コンテキストの復元
sudo restorecon -Rv /var/log/syslog-appliance/
```

### 5. rsyslog 構文チェック

```bash
sudo rsyslogd -N1
```

エラーが表示された場合は、次のステップに進まないでください。

### 6. firewalld の設定

```bash
# 受信元制限なし（全許可）
sudo firewall-cmd --permanent --add-port=514/udp
sudo firewall-cmd --permanent --add-port=514/tcp

# または受信元制限あり（例: 192.168.1.0/24 に制限）
# sudo firewall-cmd --permanent \
#   --add-rich-rule="rule family='ipv4' source address='192.168.1.0/24' port port='514' protocol='udp' accept"
# sudo firewall-cmd --permanent \
#   --add-rich-rule="rule family='ipv4' source address='192.168.1.0/24' port port='514' protocol='tcp' accept"

sudo firewall-cmd --reload
```

### 7. rsyslog 再起動

```bash
sudo systemctl restart rsyslog
sudo systemctl status rsyslog
```

---

## 受信元制限を後から変更する方法

### 現在の firewalld 設定を確認する

```bash
firewall-cmd --list-all
```

### 既存のポート許可・rich rule を削除する

```bash
# 通常のポート許可を削除
sudo firewall-cmd --permanent --remove-port=514/udp
sudo firewall-cmd --permanent --remove-port=514/tcp

# rich rule を削除する場合（rich rule の内容を確認して削除）
sudo firewall-cmd --list-rich-rules --permanent
sudo firewall-cmd --permanent --remove-rich-rule="<削除したいrule文字列>"
```

### 新しい受信元制限を追加する

```bash
# 例: 10.0.0.0/8 に変更する
sudo firewall-cmd --permanent \
    --add-rich-rule="rule family='ipv4' source address='10.0.0.0/8' port port='514' protocol='udp' accept"
sudo firewall-cmd --permanent \
    --add-rich-rule="rule family='ipv4' source address='10.0.0.0/8' port port='514' protocol='tcp' accept"
sudo firewall-cmd --reload
```

---

## ロールバック手順

セットアップを取り消す場合は、ロールバックスクリプトを使用します。

```bash
# dry-run で事前確認
sudo ./scripts/rollback-mvp0.sh --dry-run

# 実行
sudo ./scripts/rollback-mvp0.sh

# SELinux ポート設定も削除する場合
sudo ./scripts/rollback-mvp0.sh --remove-selinux-port
```

**注意:** `/var/log/syslog-appliance/raw/` 配下のログはロールバックでは削除されません。  
ログを削除する場合はオペレータが手動で判断・実行してください。

---

## トラブルシューティング

### rsyslog が起動しない

まず journalctl でエラーログを確認します。

```bash
journalctl -xeu rsyslog
```

rsyslog 設定の構文エラーが原因の場合が多いです。

```bash
# 構文チェック
sudo rsyslogd -N1
```

エラーメッセージに表示されたファイルと行番号を確認して、設定を修正してください。

### ログが /var/log/syslog-appliance/raw/ に保存されない

#### ポートがリッスンしているか確認

```bash
ss -ulnp | grep :514
ss -tlnp | grep :514
```

#### テスト送信を行う

```bash
# ローカルホストからテスト送信
logger -n 127.0.0.1 -P 514 --udp "test from localhost"
sleep 1
ls /var/log/syslog-appliance/raw/127.0.0.1/
```

#### firewalld がブロックしていないか確認

```bash
firewall-cmd --list-all
```

リモートホストから送信してログが届かない場合、送信元 IP が `allowed_sources` の範囲外の可能性があります。

### SELinux がブロックしている

SELinux の audit ログを確認します。

```bash
# AVC denied のログを確認
sudo ausearch -m avc -ts recent
# または
sudo grep 'AVC.*denied' /var/log/audit/audit.log | tail -20
```

`setsebool`, `semanage`, `audit2allow` などで対処します。詳細は [docs/08_mvp0_test.md](08_mvp0_test.md) のテストケース 7 も参照してください。

```bash
# rsyslog の SELinux ポート設定を確認
semanage port -l | grep syslogd
```

514 番ポートが `syslogd_port_t` に登録されているか確認し、登録されていなければ追加します。

```bash
sudo semanage port -a -t syslogd_port_t -p tcp 514
sudo semanage port -a -t syslogd_port_t -p udp 514
```

### ファイルのパーミッションエラー

```bash
# ディレクトリのパーミッション確認
ls -la /var/log/syslog-appliance/
ls -la /var/log/syslog-appliance/raw/

# 期待値
# drwxr-x--- root root /var/log/syslog-appliance/
# drwxr-x--- root root /var/log/syslog-appliance/raw/
```

パーミッションがおかしい場合は以下で修正します。

```bash
sudo chmod 0750 /var/log/syslog-appliance/
sudo chmod 0750 /var/log/syslog-appliance/raw/
sudo chown root:root /var/log/syslog-appliance/
sudo chown root:root /var/log/syslog-appliance/raw/
```
