# MVP 0 テスト手順書

## テストの目的

MVP 0 のセットアップ（`setup-mvp0.sh` による構築）が正しく完了していることを確認します。  
具体的には、以下の項目が正常に動作することを検証します。

- UDP/TCP ポート 514 でリモートログを受信できること
- 受信したログが正しいパス（`/var/log/syslog-appliance/raw/<送信元IP>/<YYYY-MM-DD>.log`）に保存されること
- ローカルシステムのログ（`/var/log/messages` 等）に影響がないこと
- rsyslog 停止時にポートが閉じること
- SELinux による AVC denied が発生していないこと

---

## 事前準備

以下がすべて完了していることを確認してください。

```bash
# setup-mvp0.sh が正常に実行済みであること
systemctl status rsyslog   # active (running) であること

# ポートがリッスンしていること
ss -ulnp | grep :514       # UDP 514
ss -tlnp | grep :514       # TCP 514

# firewalld が 514 ポートを許可していること
firewall-cmd --list-all

# ログ保存ディレクトリが存在すること
ls -la /var/log/syslog-appliance/raw/
```

---

## テストケース 1: 同一ホストからの UDP 送信

### 目的

syslog-appliance が稼働しているホスト自身から UDP 514 でログを送信し、  
ファイルに正しく保存されることを確認する。

### 実行コマンド（送信側 = 受信ホスト上で実行）

```bash
# テストメッセージを UDP で送信する
# -n: 送信先ホスト（ループバック）
# -P: 送信先ポート
# --udp: UDP を使用
logger -n 127.0.0.1 -P 514 --udp "MVP0-TEST-UDP-LOCAL: $(date '+%Y-%m-%d %H:%M:%S')"
```

### 確認コマンド（受信側 = 同一ホスト上で実行）

```bash
# 少し待ってからファイルが生成されているか確認
sleep 1
TODAY=$(date +%Y-%m-%d)
cat "/var/log/syslog-appliance/raw/127.0.0.1/${TODAY}.log"
```

### 期待される結果

- `/var/log/syslog-appliance/raw/127.0.0.1/` ディレクトリが作成されている
- `<YYYY-MM-DD>.log` ファイルが作成されている
- ファイル内に `MVP0-TEST-UDP-LOCAL` の文字列が含まれている
- ファイルのパーミッションが `0640 root:root` になっている

```bash
# パーミッション確認
ls -la "/var/log/syslog-appliance/raw/127.0.0.1/${TODAY}.log"
# 期待値: -rw-r----- 1 root root ... 127.0.0.1/...
```

---

## テストケース 2: 同一ホストからの TCP 送信

### 目的

syslog-appliance が稼働しているホスト自身から TCP 514 でログを送信し、  
ファイルに正しく保存されることを確認する。

### 実行コマンド（送信側 = 受信ホスト上で実行）

```bash
# テストメッセージを TCP で送信する
logger -n 127.0.0.1 -P 514 --tcp "MVP0-TEST-TCP-LOCAL: $(date '+%Y-%m-%d %H:%M:%S')"
```

### 確認コマンド（受信側 = 同一ホスト上で実行）

```bash
sleep 1
TODAY=$(date +%Y-%m-%d)
grep "MVP0-TEST-TCP-LOCAL" "/var/log/syslog-appliance/raw/127.0.0.1/${TODAY}.log"
```

### 期待される結果

- テストケース 1 と同じファイルに TCP 送信のログが追記されている
- `MVP0-TEST-TCP-LOCAL` の文字列が含まれている

---

## テストケース 3: 別ホストからの UDP 送信

### 目的

別ホスト（送信元デバイスを想定）から UDP 514 でログを送信し、  
送信元 IP アドレスのディレクトリにログが保存されることを確認する。

### 事前準備

別ホストに `logger` または `nc` コマンドが使用できること。

### 実行コマンド（送信側 = 別ホストで実行）

```bash
# <APPLIANCE_IP> を syslog-appliance のIPアドレスに置き換えて実行
APPLIANCE_IP="<syslog-applianceのIPアドレス>"

logger -n "${APPLIANCE_IP}" -P 514 --udp "MVP0-TEST-UDP-REMOTE: $(date '+%Y-%m-%d %H:%M:%S')"
```

### 確認コマンド（受信側 = syslog-appliance ホスト上で実行）

```bash
# 送信元 IP のディレクトリを確認する
SENDER_IP="<送信元ホストのIPアドレス>"
TODAY=$(date +%Y-%m-%d)

ls -la "/var/log/syslog-appliance/raw/${SENDER_IP}/"
cat "/var/log/syslog-appliance/raw/${SENDER_IP}/${TODAY}.log"
```

### 期待される結果

- `/var/log/syslog-appliance/raw/<送信元IP>/` ディレクトリが作成されている
- `<YYYY-MM-DD>.log` ファイルに `MVP0-TEST-UDP-REMOTE` が含まれている
- ディレクトリのパーミッションが `0750 root:root` になっている

```bash
# ディレクトリのパーミッション確認
ls -la "/var/log/syslog-appliance/raw/${SENDER_IP}/"
# 期待値: drwxr-x--- root root ...
```

---

## テストケース 4: 別ホストからの TCP 送信

### 目的

別ホストから TCP 514 でログを送信し、ファイルに正しく保存されることを確認する。

### 実行コマンド（送信側 = 別ホストで実行）

```bash
APPLIANCE_IP="<syslog-applianceのIPアドレス>"

logger -n "${APPLIANCE_IP}" -P 514 --tcp "MVP0-TEST-TCP-REMOTE: $(date '+%Y-%m-%d %H:%M:%S')"
```

### 確認コマンド（受信側 = syslog-appliance ホスト上で実行）

```bash
SENDER_IP="<送信元ホストのIPアドレス>"
TODAY=$(date +%Y-%m-%d)

grep "MVP0-TEST-TCP-REMOTE" "/var/log/syslog-appliance/raw/${SENDER_IP}/${TODAY}.log"
```

### 期待される結果

- テストケース 3 と同じディレクトリのログファイルに TCP 送信のログが追記されている

---

## テストケース 5: ネットワーク到達性のみのテスト（nc）

### 目的

`logger` コマンドが使用できない環境でも、`nc`（netcat）を使って  
ポートへの到達性を確認する。

### 実行コマンド（送信側 = 別ホストで実行）

```bash
APPLIANCE_IP="<syslog-applianceのIPアドレス>"

# UDP 到達性テスト（nc は UDP 送信後すぐ終了するため 1 秒待つ）
echo "<14>MVP0-NC-TEST-UDP: $(date)" | nc -u -w 1 "${APPLIANCE_IP}" 514

# TCP 到達性テスト
echo "<14>MVP0-NC-TEST-TCP: $(date)" | nc -w 3 "${APPLIANCE_IP}" 514
```

> **注意:** `nc` で送信する文字列は RFC 3164 形式の Syslog メッセージに近い形式にしています。  
> `<14>` は facility=user(1), severity=info(6) を示す PRI 値です。

### 確認コマンド（受信側 = syslog-appliance ホスト上で実行）

```bash
SENDER_IP="<送信元ホストのIPアドレス>"
TODAY=$(date +%Y-%m-%d)

grep "MVP0-NC-TEST" "/var/log/syslog-appliance/raw/${SENDER_IP}/${TODAY}.log"
```

### 期待される結果

- ファイルに `MVP0-NC-TEST-UDP` または `MVP0-NC-TEST-TCP` が含まれている
- TCP の場合、`nc` コマンドがタイムアウトせず正常に終了している

---

## テストケース 6: rsyslog 停止時にポートが閉じることの確認

### 目的

rsyslog が停止するとポート 514 のリッスンが解除されることを確認する。  
サービスとポートが正しく連動していることの確認です。

### 実行コマンド

```bash
# 1. 現在のポート状態を確認（514 がリッスンされていること）
ss -ulnp | grep :514
ss -tlnp | grep :514

# 2. rsyslog を停止する
sudo systemctl stop rsyslog

# 3. ポートが閉じていることを確認
ss -ulnp | grep :514   # 何も表示されないこと
ss -tlnp | grep :514   # 何も表示されないこと

# 4. rsyslog を再起動して元に戻す
sudo systemctl start rsyslog

# 5. ポートが再度リッスン状態になっていることを確認
ss -ulnp | grep :514
ss -tlnp | grep :514
```

### 期待される結果

- rsyslog 停止後: `ss` コマンドの出力に `:514` の行が表示されない
- rsyslog 起動後: `ss` コマンドの出力に `:514` の行が表示される（UDP/TCP 両方）

---

## テストケース 7: SELinux AVC denied が出ていないことの確認

### 目的

テスト実施中に SELinux が rsyslog の動作をブロックしていないことを確認する。  
AVC denied が記録されている場合、SELinux ポリシーの追加設定が必要な可能性があります。

### 実行コマンド

```bash
# テストケース 1〜5 の実施後に実行する

# 方法 1: ausearch で AVC ログを確認
sudo ausearch -m avc -ts recent 2>/dev/null

# 方法 2: audit ログから rsyslog 関連の AVC を確認
sudo grep 'AVC.*denied' /var/log/audit/audit.log | grep rsyslog | tail -20

# 方法 3: sealert でわかりやすい説明付きで確認（setroubleshoot-server が必要）
# sudo sealert -a /var/log/audit/audit.log
```

### 期待される結果

- rsyslog に関連する AVC denied のログが記録されていない
- または、テスト実施前後で新しい AVC denied が増加していない

### AVC denied が発生した場合の対処

```bash
# どのルールが必要かを確認
sudo audit2why < /var/log/audit/audit.log

# 必要なポリシーを生成・適用する（audit2allow が使える場合）
sudo audit2allow -M syslog_appliance < /var/log/audit/audit.log
sudo semodule -i syslog_appliance.pp
```

---

## 合格条件（MVP 0 完了の定義）

MVP 0 が完了したと判断するための合格条件は以下の通りです。  
すべての条件を満たしていることを確認してください。

| No. | 確認項目 | 確認方法 |
|---|---|---|
| 1 | rsyslog が起動している | `systemctl status rsyslog` が `active (running)` |
| 2 | UDP 514 でリッスンしている | `ss -ulnp \| grep :514` に出力がある |
| 3 | TCP 514 でリッスンしている | `ss -tlnp \| grep :514` に出力がある |
| 4 | UDP ローカル送信でログが保存される | テストケース 1 の期待結果を満たす |
| 5 | TCP ローカル送信でログが保存される | テストケース 2 の期待結果を満たす |
| 6 | 別ホストからのログが送信元 IP ディレクトリに保存される | テストケース 3 または 4 の期待結果を満たす |
| 7 | rsyslog 停止時にポートが閉じる | テストケース 6 の期待結果を満たす |
| 8 | SELinux AVC denied が発生していない | テストケース 7 の期待結果を満たす |
| 9 | ローカル syslog への影響がない | テスト中も `/var/log/messages` に受信ログが混入しない |
| 10 | ファイル・ディレクトリのパーミッションが正しい | ファイル `0640`、ディレクトリ `0750`、所有者 `root:root` |

### 確認コマンドまとめ

```bash
# 合格条件をまとめて確認するコマンド例

echo "=== rsyslog ステータス ==="
systemctl status rsyslog --no-pager -l | head -5

echo "=== Listen ポート ==="
ss -ulnp | grep :514
ss -tlnp | grep :514

echo "=== firewalld 設定 ==="
firewall-cmd --list-all

echo "=== ログディレクトリ ==="
ls -la /var/log/syslog-appliance/raw/

echo "=== SELinux ステータス ==="
getenforce

echo "=== 直近の AVC denied ==="
sudo ausearch -m avc -ts recent 2>/dev/null | tail -20 || echo "ausearch 利用不可"
```

### ローカル syslog への影響がないことの確認

```bash
# テスト送信の前後で /var/log/messages の末尾を確認し、
# 受信ログが混入していないことを確認する

tail -20 /var/log/messages

# logger でテスト送信
logger -n 127.0.0.1 -P 514 --udp "ISOLATION-TEST-$(date +%s)"
sleep 1

# /var/log/messages に ISOLATION-TEST が含まれていないことを確認
grep "ISOLATION-TEST" /var/log/messages && echo "NG: messages に混入" || echo "OK: messages への混入なし"
```
