# scripts ディレクトリ

## このディレクトリの役割

syslog-appliance のセットアップ・ロールバック用シェルスクリプトを置くディレクトリです。  
各スクリプトは Rocky Linux 9 上で root 権限で実行することを前提としています。

---

## スクリプト一覧

| スクリプト名 | 役割 |
|---|---|
| `setup-mvp0.sh` | MVP 0 のセットアップを自動化する。rsyslog 設定・ログディレクトリ・firewalld・SELinux の設定を行う。 |
| `rollback-mvp0.sh` | MVP 0 の変更を取り消す。rsyslog 設定の削除・firewalld の設定削除を行う。 |

---

## 実行前の注意

**必ず `--dry-run` で事前確認してから本番実行してください。**

```bash
sudo ./scripts/setup-mvp0.sh --dry-run
```

dry-run モードでは、実際の変更を一切行わず、実行予定のコマンドを表示するだけです。  
問題なければ `--dry-run` を外して本番実行します。

---

## setup-mvp0.sh の使い方

### 基本的な実行（受信元制限なし）

```bash
sudo ./scripts/setup-mvp0.sh
```

すべての送信元 IP アドレスから UDP/TCP 514 を受信します。

### 受信元を特定ネットワークに制限する場合

```bash
# 1 つのネットワークに制限
sudo ./scripts/setup-mvp0.sh --allow-from 192.168.1.0/24

# 複数のネットワークに制限（カンマ区切り）
sudo ./scripts/setup-mvp0.sh --allow-from 192.168.1.0/24,10.0.0.0/8
```

firewalld の rich rule を使って、指定した CIDR からのみアクセスを許可します。

### dry-run で事前確認

```bash
# 受信元制限なしの dry-run
sudo ./scripts/setup-mvp0.sh --dry-run

# 受信元制限ありの dry-run
sudo ./scripts/setup-mvp0.sh --dry-run --allow-from 192.168.1.0/24
```

---

## rollback-mvp0.sh の使い方

### 基本的な実行（SELinux ポート設定は保持）

```bash
sudo ./scripts/rollback-mvp0.sh
```

rsyslog 設定ファイルの削除・rsyslog 再起動・firewalld から 514/udp, 514/tcp の許可を削除します。  
SELinux のポート設定はデフォルトでは削除しません（他のサービスへの影響を防ぐため）。

### SELinux ポート設定も削除する場合

```bash
sudo ./scripts/rollback-mvp0.sh --remove-selinux-port
```

### dry-run で事前確認

```bash
sudo ./scripts/rollback-mvp0.sh --dry-run
```

---

## 補足

- `/var/log/syslog-appliance/raw/` 配下の受信済みログはロールバックしても削除されません。  
  ログを削除する場合はオペレータが手動で判断・実行してください。
- セットアップ時に既存の rsyslog 設定ファイルが存在した場合、  
  `/var/log/syslog-appliance/.backup/` にタイムスタンプ付きでバックアップされます。
- 詳細なセットアップ手順は [docs/07_mvp0_setup.md](../docs/07_mvp0_setup.md) を参照してください。
- テスト手順は [docs/08_mvp0_test.md](../docs/08_mvp0_test.md) を参照してください。
