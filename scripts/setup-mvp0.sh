#!/usr/bin/env bash
# =============================================================================
# setup-mvp0.sh
#
# 概要:
#   syslog-appliance MVP 0 のセットアップスクリプト。
#   Rocky Linux 9 上で rsyslog によるリモートログ受信環境を構築します。
#
#   以下の作業を自動化します:
#     1. 前提チェック（rsyslog, firewalld, SELinux 状態確認）
#     2. バックアップディレクトリ作成
#     3. 既存設定ファイルのバックアップ
#     4. ログ保存ディレクトリ（/var/log/syslog-appliance/raw/）作成
#     5. アプライアンス設定ディレクトリ（/etc/syslog-appliance/）作成
#     6. rsyslog 設定ファイルの配置
#     7. 設定雛形ファイルのコピー
#     8. SELinux コンテキスト設定
#     9. rsyslog 構文チェック
#    10. firewalld へのポート許可追加
#    11. rsyslog 再起動
#    12. logrotate 設定を配置
#    13. ディスク使用量監視スクリプトのセットアップ
#    14. 最終確認情報表示
#
# 実行例:
#   sudo ./scripts/setup-mvp0.sh
#   sudo ./scripts/setup-mvp0.sh --dry-run
#   sudo ./scripts/setup-mvp0.sh --allow-from 192.168.1.0/24,10.0.0.0/8
#
# 戻し方:
#   scripts/rollback-mvp0.sh を実行してください。
#   sudo ./scripts/rollback-mvp0.sh
# =============================================================================
set -euo pipefail

# =============================================================================
# 定数・パス定義
# =============================================================================
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RSYSLOG_CONF_SRC="${REPO_ROOT}/rsyslog/10-syslog-appliance.conf"
RSYSLOG_CONF_DEST="/etc/rsyslog.d/10-syslog-appliance.conf"
APPLIANCE_CONF_SRC="${REPO_ROOT}/etc/syslog-appliance/appliance.conf.example"
DEVICES_YAML_SRC="${REPO_ROOT}/etc/syslog-appliance/devices.yaml.example"
LOGROTATE_CONF_SRC="${REPO_ROOT}/logrotate/syslog-appliance"
LOGROTATE_CONF_DEST="/etc/logrotate.d/syslog-appliance"
ETC_DIR="/etc/syslog-appliance"
LOG_DIR="/var/log/syslog-appliance/raw"
BACKUP_DIR="/var/log/syslog-appliance/.backup"

# ディスク使用量監視スクリプト関連パス
DISK_CHECK_SCRIPT_SRC="${REPO_ROOT}/scripts/check-disk-usage.sh"
DISK_CHECK_SCRIPT_DEST="/opt/syslog-appliance/scripts/check-disk-usage.sh"
DISK_CHECK_SCRIPT_DIR="/opt/syslog-appliance/scripts"
DISK_CHECK_SERVICE_SRC="${REPO_ROOT}/systemd/syslog-appliance-disk-check.service"
DISK_CHECK_SERVICE_DEST="/etc/systemd/system/syslog-appliance-disk-check.service"
DISK_CHECK_TIMER_SRC="${REPO_ROOT}/systemd/syslog-appliance-disk-check.timer"
DISK_CHECK_TIMER_DEST="/etc/systemd/system/syslog-appliance-disk-check.timer"
NOTIFICATION_DIR="/var/lib/syslog-appliance/notifications"

SYSLOG_PORT="514"
SYSLOG_PROTO_UDP="udp"
SYSLOG_PROTO_TCP="tcp"
SELINUX_PORT_TYPE="syslogd_port_t"

# =============================================================================
# フラグ初期化
# =============================================================================
DRY_RUN=false
ALLOW_FROM=""

# =============================================================================
# カラー出力設定
# =============================================================================
# tty に出力している場合のみ ANSI カラーを使用する
if tty -s 2>/dev/null; then
    C_RESET='\033[0m'
    C_INFO='\033[0;36m'    # シアン
    C_OK='\033[0;32m'      # 緑
    C_WARN='\033[0;33m'    # 黄
    C_ERROR='\033[0;31m'   # 赤
else
    C_RESET=''
    C_INFO=''
    C_OK=''
    C_WARN=''
    C_ERROR=''
fi

# =============================================================================
# ログ出力関数
# =============================================================================
log_info()  { echo -e "${C_INFO}[INFO]${C_RESET}  $*"; }
log_ok()    { echo -e "${C_OK}[OK]${C_RESET}    $*"; }
log_warn()  { echo -e "${C_WARN}[WARN]${C_RESET}  $*"; }
log_error() { echo -e "${C_ERROR}[ERROR]${C_RESET} $*" >&2; }

# dry-run 対応の実行関数
# DRY_RUN=true の場合はコマンドを表示するだけで実行しない
run_cmd() {
    if [[ "${DRY_RUN}" == true ]]; then
        echo -e "${C_WARN}[DRY-RUN]${C_RESET} $*"
    else
        "$@"
    fi
}

# =============================================================================
# ヘルプ表示
# =============================================================================
show_help() {
    cat <<EOF
使い方:
  sudo $0 [オプション]

オプション:
  --allow-from <CIDR[,CIDR...]>
      firewalld で受信元 IP アドレスを制限する。
      カンマ区切りで複数の CIDR を指定可能。
      指定しない場合はすべての送信元から受信する（制限なし）。
      例: --allow-from 192.168.1.0/24,10.0.0.0/8

  --dry-run
      実際の変更は行わず、実行予定のコマンドを表示するだけ。
      事前確認に使用してください。

  --help
      このヘルプを表示して終了する。

実行例:
  sudo $0
  sudo $0 --dry-run
  sudo $0 --allow-from 192.168.1.0/24

戻し方:
  sudo ${SCRIPT_DIR}/rollback-mvp0.sh
EOF
}

# =============================================================================
# 引数解析
# =============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --allow-from)
            if [[ -z "${2:-}" ]]; then
                log_error "--allow-from には CIDR を指定してください。"
                exit 1
            fi
            ALLOW_FROM="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            log_error "不明なオプションです: $1"
            show_help
            exit 1
            ;;
    esac
done

# =============================================================================
# メイン処理開始
# =============================================================================
echo ""
log_info "=========================================="
log_info " syslog-appliance MVP 0 セットアップ開始"
log_info "=========================================="
[[ "${DRY_RUN}" == true ]] && log_warn "DRY-RUN モード: 実際の変更は行いません。"
echo ""

# =============================================================================
# ステップ 0: root 権限チェック
# =============================================================================
log_info "[Step 0] 実行権限の確認..."
if [[ $EUID -ne 0 ]]; then
    log_error "このスクリプトは root 権限で実行してください。"
    log_error "  sudo $0 $*"
    exit 1
fi
log_ok "root 権限で実行中。"

# =============================================================================
# ステップ 1: 前提チェック
# =============================================================================
log_info "[Step 1] 前提条件の確認..."

# rsyslog インストール確認
if ! command -v rsyslogd &>/dev/null; then
    log_error "rsyslog がインストールされていません。"
    log_error "  sudo dnf install -y rsyslog"
    exit 1
fi
RSYSLOG_VER=$(rsyslogd -v 2>&1 | head -1 || true)
log_ok "rsyslog 確認: ${RSYSLOG_VER}"

# firewalld 稼働確認
if ! systemctl is-active --quiet firewalld; then
    log_error "firewalld が稼働していません。"
    log_error "  sudo systemctl start firewalld"
    exit 1
fi
log_ok "firewalld は稼働中。"

# SELinux 状態確認（無効でも続行するが警告を出す）
SELINUX_STATUS=$(getenforce 2>/dev/null || echo "Unknown")
if [[ "${SELINUX_STATUS}" == "Disabled" ]]; then
    log_warn "SELinux が無効です。SELinux 関連の手順をスキップします。"
elif [[ "${SELINUX_STATUS}" == "Permissive" ]]; then
    log_warn "SELinux が Permissive モードです。ポート設定は行いますが、強制はされません。"
else
    log_ok "SELinux ステータス: ${SELINUX_STATUS}"
fi

# semanage コマンドの確認（SELinux が有効な場合のみ）
if [[ "${SELINUX_STATUS}" != "Disabled" ]]; then
    if ! command -v semanage &>/dev/null; then
        log_warn "semanage コマンドが見つかりません。policycoreutils-python-utils をインストールしてください。"
        log_warn "  sudo dnf install -y policycoreutils-python-utils"
        log_warn "semanage がないため SELinux ポート設定をスキップします。"
        SELINUX_STATUS="NoSemanage"
    fi
fi

# ソース設定ファイルの存在確認
if [[ ! -f "${RSYSLOG_CONF_SRC}" ]]; then
    log_error "rsyslog 設定ファイルが見つかりません: ${RSYSLOG_CONF_SRC}"
    exit 1
fi
log_ok "ソースファイル確認: ${RSYSLOG_CONF_SRC}"

# =============================================================================
# ステップ 2: バックアップディレクトリ作成
# =============================================================================
log_info "[Step 2] バックアップディレクトリを作成..."
run_cmd mkdir -p "${BACKUP_DIR}"
run_cmd chmod 0750 "${BACKUP_DIR}"
run_cmd chown root:root "${BACKUP_DIR}"
log_ok "バックアップディレクトリ: ${BACKUP_DIR}"

# =============================================================================
# ステップ 3: 既存 rsyslog 設定ファイルのバックアップ
# =============================================================================
log_info "[Step 3] 既存 rsyslog 設定ファイルのバックアップ..."
if [[ -f "${RSYSLOG_CONF_DEST}" ]]; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    BACKUP_FILE="${BACKUP_DIR}/10-syslog-appliance.conf.${TIMESTAMP}"
    run_cmd cp "${RSYSLOG_CONF_DEST}" "${BACKUP_FILE}"
    log_ok "既存ファイルをバックアップ: ${BACKUP_FILE}"
else
    log_info "既存の設定ファイルはありません。スキップします。"
fi

# /etc/rsyslog.conf の念のためのバックアップ（変更はしない）
if [[ -f /etc/rsyslog.conf ]]; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    if [[ "${DRY_RUN}" == false ]]; then
        # DRY_RUN 時は cp を行わない
        cp /etc/rsyslog.conf "${BACKUP_DIR}/rsyslog.conf.${TIMESTAMP}" 2>/dev/null || true
    else
        echo -e "${C_WARN}[DRY-RUN]${C_RESET} cp /etc/rsyslog.conf ${BACKUP_DIR}/rsyslog.conf.${TIMESTAMP}"
    fi
    log_ok "/etc/rsyslog.conf のバックアップを作成（変更は行いません）。"
fi

# =============================================================================
# ステップ 4: ログ保存ディレクトリ作成
# =============================================================================
log_info "[Step 4] ログ保存ディレクトリを作成..."
run_cmd mkdir -p "${LOG_DIR}"
run_cmd chmod 0750 "${LOG_DIR}"
run_cmd chown root:root "${LOG_DIR}"
# 親ディレクトリ /var/log/syslog-appliance にも権限を設定
run_cmd chmod 0750 "$(dirname "${LOG_DIR}")"
run_cmd chown root:root "$(dirname "${LOG_DIR}")"
log_ok "ログ保存ディレクトリ: ${LOG_DIR}"

# =============================================================================
# ステップ 5: アプライアンス設定ディレクトリ作成
# =============================================================================
log_info "[Step 5] アプライアンス設定ディレクトリを作成..."
run_cmd mkdir -p "${ETC_DIR}"
run_cmd chmod 0750 "${ETC_DIR}"
run_cmd chown root:root "${ETC_DIR}"
log_ok "設定ディレクトリ: ${ETC_DIR}"

# =============================================================================
# ステップ 6: rsyslog 設定ファイルの配置
# =============================================================================
log_info "[Step 6] rsyslog 設定ファイルを配置..."
run_cmd cp "${RSYSLOG_CONF_SRC}" "${RSYSLOG_CONF_DEST}"
run_cmd chown root:root "${RSYSLOG_CONF_DEST}"
run_cmd chmod 0644 "${RSYSLOG_CONF_DEST}"
log_ok "設定ファイルを配置: ${RSYSLOG_CONF_DEST}"

# =============================================================================
# ステップ 7: 設定雛形ファイルのコピー
# =============================================================================
log_info "[Step 7] 設定雛形ファイルをコピー..."
if [[ -f "${APPLIANCE_CONF_SRC}" ]]; then
    run_cmd cp "${APPLIANCE_CONF_SRC}" "${ETC_DIR}/appliance.conf.example"
    run_cmd chown root:root "${ETC_DIR}/appliance.conf.example"
    run_cmd chmod 0644 "${ETC_DIR}/appliance.conf.example"
    log_ok "appliance.conf.example をコピー。"
fi
if [[ -f "${DEVICES_YAML_SRC}" ]]; then
    run_cmd cp "${DEVICES_YAML_SRC}" "${ETC_DIR}/devices.yaml.example"
    run_cmd chown root:root "${ETC_DIR}/devices.yaml.example"
    run_cmd chmod 0644 "${ETC_DIR}/devices.yaml.example"
    log_ok "devices.yaml.example をコピー。"
fi

# =============================================================================
# ステップ 8: SELinux コンテキスト設定
# =============================================================================
log_info "[Step 8] SELinux コンテキストを設定..."
if [[ "${SELINUX_STATUS}" == "Disabled" || "${SELINUX_STATUS}" == "NoSemanage" ]]; then
    log_warn "SELinux 無効 or semanage なしのため、このステップをスキップします。"
else
    # TCP 514 が syslogd_port_t に登録済みか確認（冪等処理）
    # awk で tcp 行のみを抽出してからポート番号を境界付きで判定する。
    # 単純な grep '514' では UDP 行の 514 に誤マッチするため、プロトコル列で絞り込む。
    if semanage port -l \
       | awk -v type="${SELINUX_PORT_TYPE}" '$1==type && $2=="tcp"' \
       | grep -qE '(^|[, ])'"${SYSLOG_PORT}"'([, ]|$)'; then
        log_ok "TCP ${SYSLOG_PORT} は既に ${SELINUX_PORT_TYPE} に登録済みです。スキップします。"
    else
        log_info "TCP ${SYSLOG_PORT} を ${SELINUX_PORT_TYPE} に登録します..."
        run_cmd semanage port -a -t "${SELINUX_PORT_TYPE}" -p tcp "${SYSLOG_PORT}"
        log_ok "TCP ${SYSLOG_PORT} を ${SELINUX_PORT_TYPE} に登録しました。"
    fi

    # UDP 514 の確認（通常は syslogd_port_t にデフォルト含まれているが念のため確認）
    # TCP と同じロジックで udp 行のみを抽出して厳密判定する。
    if semanage port -l \
       | awk -v type="${SELINUX_PORT_TYPE}" '$1==type && $2=="udp"' \
       | grep -qE '(^|[, ])'"${SYSLOG_PORT}"'([, ]|$)'; then
        log_ok "UDP ${SYSLOG_PORT} は既に ${SELINUX_PORT_TYPE} に含まれています。"
    else
        log_info "UDP ${SYSLOG_PORT} を ${SELINUX_PORT_TYPE} に登録します..."
        run_cmd semanage port -a -t "${SELINUX_PORT_TYPE}" -p udp "${SYSLOG_PORT}" || \
            log_warn "UDP ${SYSLOG_PORT} の登録に失敗しました（既登録の可能性あり）。"
    fi

    # /var/log/syslog-appliance/ に SELinux コンテキストを復元
    log_info "/var/log/syslog-appliance/ の SELinux コンテキストを設定します..."
    run_cmd restorecon -Rv /var/log/syslog-appliance/
    log_ok "SELinux コンテキスト設定完了。"
fi

# =============================================================================
# ステップ 9: rsyslog 構文チェック
# =============================================================================
log_info "[Step 9] rsyslog 設定の構文チェック..."
if [[ "${DRY_RUN}" == true ]]; then
    log_warn "[DRY-RUN] rsyslogd -N1 の実行をスキップします。"
else
    if ! rsyslogd -N1 2>&1; then
        log_error "rsyslog の構文チェックに失敗しました。"
        log_error "設定ファイルを確認してください: ${RSYSLOG_CONF_DEST}"
        log_error "修正後に再度このスクリプトを実行してください。"
        exit 1
    fi
    log_ok "rsyslog 構文チェック OK。"
fi

# =============================================================================
# ステップ 10: firewalld へのポート許可追加
# =============================================================================
log_info "[Step 10] firewalld にポートを許可..."

if [[ -n "${ALLOW_FROM}" ]]; then
    # --allow-from 指定あり: rich rule で送信元を制限
    log_info "受信元制限モード: ${ALLOW_FROM}"
    IFS=',' read -ra CIDRS <<< "${ALLOW_FROM}"
    for CIDR in "${CIDRS[@]}"; do
        CIDR="${CIDR// /}"  # 前後のスペースを除去
        log_info "  Rich rule を追加: ${CIDR} からの UDP/TCP ${SYSLOG_PORT} を許可..."
        run_cmd firewall-cmd --permanent \
            --add-rich-rule="rule family='ipv4' source address='${CIDR}' port port='${SYSLOG_PORT}' protocol='${SYSLOG_PROTO_UDP}' accept"
        run_cmd firewall-cmd --permanent \
            --add-rich-rule="rule family='ipv4' source address='${CIDR}' port port='${SYSLOG_PORT}' protocol='${SYSLOG_PROTO_TCP}' accept"
        log_ok "  Rich rule 追加: ${CIDR} -> ${SYSLOG_PORT}/udp, ${SYSLOG_PORT}/tcp"
    done
else
    # --allow-from 指定なし: 全許可
    log_info "全送信元許可モード（制限なし）..."
    # 既に許可されているか確認（冪等処理）
    if firewall-cmd --query-port="${SYSLOG_PORT}/${SYSLOG_PROTO_UDP}" --permanent &>/dev/null; then
        log_ok "UDP ${SYSLOG_PORT} は既に許可済みです。"
    else
        run_cmd firewall-cmd --permanent --add-port="${SYSLOG_PORT}/${SYSLOG_PROTO_UDP}"
        log_ok "UDP ${SYSLOG_PORT} を許可しました。"
    fi
    if firewall-cmd --query-port="${SYSLOG_PORT}/${SYSLOG_PROTO_TCP}" --permanent &>/dev/null; then
        log_ok "TCP ${SYSLOG_PORT} は既に許可済みです。"
    else
        run_cmd firewall-cmd --permanent --add-port="${SYSLOG_PORT}/${SYSLOG_PROTO_TCP}"
        log_ok "TCP ${SYSLOG_PORT} を許可しました。"
    fi
fi

# firewalld リロード
run_cmd firewall-cmd --reload
log_ok "firewalld をリロードしました。"

# =============================================================================
# ステップ 11: rsyslog 再起動
# =============================================================================
log_info "[Step 11] rsyslog を再起動..."
run_cmd systemctl restart rsyslog
if [[ "${DRY_RUN}" == false ]]; then
    if systemctl is-active --quiet rsyslog; then
        log_ok "rsyslog が正常に起動しました。"
    else
        log_error "rsyslog の起動に失敗しました。"
        log_error "  journalctl -xeu rsyslog で詳細を確認してください。"
        exit 1
    fi
fi

# =============================================================================
# ステップ 12: logrotate 設定を配置
# =============================================================================
log_info "[Step 12] logrotate 設定ファイルを配置..."

# ソースファイルの存在確認
if [[ ! -f "${LOGROTATE_CONF_SRC}" ]]; then
    log_error "logrotate 設定ファイルが見つかりません: ${LOGROTATE_CONF_SRC}"
    exit 1
fi

# 既存ファイルのバックアップ
if [[ -f "${LOGROTATE_CONF_DEST}" ]]; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    LOGROTATE_BACKUP="${BACKUP_DIR}/syslog-appliance.logrotate.${TIMESTAMP}"
    run_cmd cp "${LOGROTATE_CONF_DEST}" "${LOGROTATE_BACKUP}"
    log_ok "既存 logrotate 設定をバックアップ: ${LOGROTATE_BACKUP}"
fi

# 配置・権限設定
run_cmd cp "${LOGROTATE_CONF_SRC}" "${LOGROTATE_CONF_DEST}"
run_cmd chown root:root "${LOGROTATE_CONF_DEST}"
run_cmd chmod 0644 "${LOGROTATE_CONF_DEST}"
log_ok "logrotate 設定ファイルを配置: ${LOGROTATE_CONF_DEST}"

# 構文チェック（dry-run でも実行して設定の正しさを確認する）
log_info "logrotate 設定の構文チェック（dry-run）..."
if [[ "${DRY_RUN}" == true ]]; then
    echo -e "${C_WARN}[DRY-RUN]${C_RESET} logrotate -d ${LOGROTATE_CONF_DEST}"
else
    if logrotate -d "${LOGROTATE_CONF_DEST}" 2>&1; then
        log_ok "logrotate 構文チェック OK。"
    else
        log_warn "logrotate の構文チェックで警告が出ました。設定を確認してください: ${LOGROTATE_CONF_DEST}"
    fi
fi

# =============================================================================
# ステップ 13: ディスク使用量監視スクリプトのセットアップ
# =============================================================================
log_info "[Step 13] ディスク使用量監視スクリプトをセットアップ..."

# ソースファイルの存在確認
if [[ ! -f "${DISK_CHECK_SCRIPT_SRC}" ]]; then
    log_error "check-disk-usage.sh が見つかりません: ${DISK_CHECK_SCRIPT_SRC}"
    exit 1
fi
if [[ ! -f "${DISK_CHECK_SERVICE_SRC}" ]]; then
    log_error "systemd サービスファイルが見つかりません: ${DISK_CHECK_SERVICE_SRC}"
    exit 1
fi
if [[ ! -f "${DISK_CHECK_TIMER_SRC}" ]]; then
    log_error "systemd タイマーファイルが見つかりません: ${DISK_CHECK_TIMER_SRC}"
    exit 1
fi

# 配置先スクリプトディレクトリの作成（存在しない場合のみ）
run_cmd mkdir -p "${DISK_CHECK_SCRIPT_DIR}"
run_cmd chown root:root "${DISK_CHECK_SCRIPT_DIR}"
run_cmd chmod 0755 "${DISK_CHECK_SCRIPT_DIR}"

# 監視スクリプトを配置（実行権限: 0755）
run_cmd cp "${DISK_CHECK_SCRIPT_SRC}" "${DISK_CHECK_SCRIPT_DEST}"
run_cmd chown root:root "${DISK_CHECK_SCRIPT_DEST}"
run_cmd chmod 0755 "${DISK_CHECK_SCRIPT_DEST}"
log_ok "監視スクリプトを配置: ${DISK_CHECK_SCRIPT_DEST}"

# systemd サービスファイルを配置（権限: 0644）
run_cmd cp "${DISK_CHECK_SERVICE_SRC}" "${DISK_CHECK_SERVICE_DEST}"
run_cmd chown root:root "${DISK_CHECK_SERVICE_DEST}"
run_cmd chmod 0644 "${DISK_CHECK_SERVICE_DEST}"
log_ok "サービスファイルを配置: ${DISK_CHECK_SERVICE_DEST}"

# systemd タイマーファイルを配置（権限: 0644）
run_cmd cp "${DISK_CHECK_TIMER_SRC}" "${DISK_CHECK_TIMER_DEST}"
run_cmd chown root:root "${DISK_CHECK_TIMER_DEST}"
run_cmd chmod 0644 "${DISK_CHECK_TIMER_DEST}"
log_ok "タイマーファイルを配置: ${DISK_CHECK_TIMER_DEST}"

# 通知ファイル配置ディレクトリの作成（Web UI 用・権限: 0750）
run_cmd mkdir -p "${NOTIFICATION_DIR}"
run_cmd chown root:root "${NOTIFICATION_DIR}"
run_cmd chmod 0750 "${NOTIFICATION_DIR}"
log_ok "通知ファイルディレクトリを作成: ${NOTIFICATION_DIR}"

# systemd デーモンをリロードしてタイマーを有効化・開始する
run_cmd systemctl daemon-reload
run_cmd systemctl enable --now syslog-appliance-disk-check.timer
if [[ "${DRY_RUN}" == false ]]; then
    if systemctl is-active --quiet syslog-appliance-disk-check.timer; then
        log_ok "ディスク使用量監視タイマーが有効化・起動されました。"
    else
        log_warn "タイマーの起動状態を確認できませんでした。"
        log_warn "  sudo systemctl status syslog-appliance-disk-check.timer を確認してください。"
    fi
fi

# =============================================================================
# ステップ 14: 最終確認情報の表示
# =============================================================================
echo ""
log_info "=========================================="
log_info " セットアップ完了 - 最終確認情報"
log_info "=========================================="

log_info "--- rsyslog ステータス ---"
if [[ "${DRY_RUN}" == false ]]; then
    systemctl status rsyslog --no-pager -l | head -10 || true
fi

log_info "--- Listen ポート ---"
if [[ "${DRY_RUN}" == false ]]; then
    ss -ulnp | grep ":${SYSLOG_PORT}" || log_warn "UDP ${SYSLOG_PORT} のリッスンが確認できません。"
    ss -tlnp | grep ":${SYSLOG_PORT}" || log_warn "TCP ${SYSLOG_PORT} のリッスンが確認できません。"
fi

log_info "--- firewalld 設定 ---"
if [[ "${DRY_RUN}" == false ]]; then
    firewall-cmd --list-all || true
fi

log_info "--- SELinux ステータス ---"
getenforce 2>/dev/null || echo "Unknown"

echo ""
log_ok "=========================================="
log_ok " MVP 0 セットアップが完了しました！"
log_ok "=========================================="
echo ""
log_info "次のステップ:"
log_info "  テスト手順: docs/08_mvp0_test.md を参照してください。"
log_info "  ロールバック: sudo ${SCRIPT_DIR}/rollback-mvp0.sh"
echo ""
