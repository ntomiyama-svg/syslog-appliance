#!/usr/bin/env bash
# =============================================================================
# rollback-mvp0.sh
#
# 概要:
#   syslog-appliance MVP 0 のロールバックスクリプト。
#   setup-mvp0.sh で行った変更を取り消します。
#
#   以下の作業を自動化します:
#     1. rsyslog 設定ファイルの削除（バックアップとして移動）
#     2. rsyslog 構文チェック
#     3. rsyslog 再起動
#     4. firewalld からの 514/udp, 514/tcp 許可を削除
#     5. （オプション）SELinux ポート設定の削除
#     6. 最終確認情報表示
#
#   ※ /var/log/syslog-appliance/raw/ 配下のログは削除しません。
#      ログの削除はオペレータが判断して手動で行ってください。
#
# 実行例:
#   sudo ./scripts/rollback-mvp0.sh
#   sudo ./scripts/rollback-mvp0.sh --dry-run
#   sudo ./scripts/rollback-mvp0.sh --remove-selinux-port
# =============================================================================
set -euo pipefail

# =============================================================================
# 定数・パス定義
# =============================================================================
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

RSYSLOG_CONF_DEST="/etc/rsyslog.d/10-syslog-appliance.conf"
BACKUP_DIR="/var/log/syslog-appliance/.backup"

SYSLOG_PORT="514"
SYSLOG_PROTO_UDP="udp"
SYSLOG_PROTO_TCP="tcp"
SELINUX_PORT_TYPE="syslogd_port_t"

# =============================================================================
# フラグ初期化
# =============================================================================
DRY_RUN=false
REMOVE_SELINUX_PORT=false

# =============================================================================
# カラー出力設定
# =============================================================================
if tty -s 2>/dev/null; then
    C_RESET='\033[0m'
    C_INFO='\033[0;36m'
    C_OK='\033[0;32m'
    C_WARN='\033[0;33m'
    C_ERROR='\033[0;31m'
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
  --remove-selinux-port
      SELinux に追加したポート設定（syslogd_port_t 514/tcp, 514/udp）を削除する。
      デフォルトでは削除しません（他のサービスへの影響を防ぐため）。

  --dry-run
      実際の変更は行わず、実行予定のコマンドを表示するだけ。

  --help
      このヘルプを表示して終了する。

注意:
  /var/log/syslog-appliance/raw/ 配下のログは削除しません。
  ログの削除はオペレータが手動で行ってください。
EOF
}

# =============================================================================
# 引数解析
# =============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --remove-selinux-port)
            REMOVE_SELINUX_PORT=true
            shift
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
log_info " syslog-appliance MVP 0 ロールバック開始"
log_info "=========================================="
[[ "${DRY_RUN}" == true ]] && log_warn "DRY-RUN モード: 実際の変更は行いません。"
echo ""

# =============================================================================
# ステップ 0: root 権限チェック
# =============================================================================
log_info "[Step 0] 実行権限の確認..."
if [[ $EUID -ne 0 ]]; then
    log_error "このスクリプトは root 権限で実行してください。"
    log_error "  sudo $0"
    exit 1
fi
log_ok "root 権限で実行中。"

# =============================================================================
# ステップ 1: rsyslog 設定ファイルの削除（バックアップとして移動）
# =============================================================================
log_info "[Step 1] rsyslog 設定ファイルを削除（バックアップとして移動）..."
if [[ -f "${RSYSLOG_CONF_DEST}" ]]; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    REMOVED_FILE="${BACKUP_DIR}/10-syslog-appliance.conf.removed.${TIMESTAMP}"
    run_cmd mkdir -p "${BACKUP_DIR}"
    run_cmd mv "${RSYSLOG_CONF_DEST}" "${REMOVED_FILE}"
    log_ok "設定ファイルを移動: ${RSYSLOG_CONF_DEST} -> ${REMOVED_FILE}"
    log_info "（削除されたファイルは ${BACKUP_DIR} に保存されています）"
else
    log_warn "rsyslog 設定ファイルが見つかりません: ${RSYSLOG_CONF_DEST}"
    log_warn "既にロールバック済みか、手動で削除された可能性があります。"
fi

# =============================================================================
# ステップ 2: rsyslog 構文チェック
# =============================================================================
log_info "[Step 2] rsyslog 設定の構文チェック..."
if [[ "${DRY_RUN}" == true ]]; then
    log_warn "[DRY-RUN] rsyslogd -N1 の実行をスキップします。"
else
    if ! rsyslogd -N1 2>&1; then
        log_error "rsyslog の構文チェックに失敗しました。"
        log_error "rsyslog を再起動せず、処理を中断します。"
        log_error "  /etc/rsyslog.conf と /etc/rsyslog.d/ の設定を確認してください。"
        exit 1
    fi
    log_ok "rsyslog 構文チェック OK。"
fi

# =============================================================================
# ステップ 3: rsyslog 再起動
# =============================================================================
log_info "[Step 3] rsyslog を再起動..."
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
# ステップ 4: firewalld から 514/udp, 514/tcp の許可を削除
# =============================================================================
log_info "[Step 4] firewalld の 514/udp, 514/tcp 許可を削除..."

# 通常のポート許可を削除（--add-port で追加されたもの）
for PROTO in "${SYSLOG_PROTO_UDP}" "${SYSLOG_PROTO_TCP}"; do
    if [[ "${DRY_RUN}" == true ]]; then
        echo -e "${C_WARN}[DRY-RUN]${C_RESET} firewall-cmd --permanent --remove-port=${SYSLOG_PORT}/${PROTO}"
    elif firewall-cmd --query-port="${SYSLOG_PORT}/${PROTO}" --permanent &>/dev/null; then
        firewall-cmd --permanent --remove-port="${SYSLOG_PORT}/${PROTO}"
        log_ok "${PROTO^^} ${SYSLOG_PORT} の許可を削除しました。"
    else
        log_info "${PROTO^^} ${SYSLOG_PORT} の通常ポート許可はありません。スキップします。"
    fi
done

# Rich rule の削除（--allow-from で追加されたもの）
# 既存の rich rule から syslog-appliance 関連のものを検索して削除する
log_info "Rich rule を確認中..."
if [[ "${DRY_RUN}" == false ]]; then
    # port="514" を含む rich rule を取得
    while IFS= read -r RULE; do
        if [[ "${RULE}" =~ port.*port=\"514\" ]]; then
            log_info "削除対象の Rich rule: ${RULE}"
            firewall-cmd --permanent --remove-rich-rule="${RULE}" && \
                log_ok "Rich rule を削除: ${RULE}" || \
                log_warn "Rich rule の削除に失敗しました: ${RULE}"
        fi
    done < <(firewall-cmd --list-rich-rules --permanent 2>/dev/null || true)
else
    log_warn "[DRY-RUN] Rich rule の削除をスキップします。"
fi

# firewalld リロード
run_cmd firewall-cmd --reload
log_ok "firewalld をリロードしました。"

# =============================================================================
# ステップ 5: SELinux ポート設定の削除（オプション）
# =============================================================================
log_info "[Step 5] SELinux ポート設定の確認..."
if [[ "${REMOVE_SELINUX_PORT}" == true ]]; then
    SELINUX_STATUS=$(getenforce 2>/dev/null || echo "Disabled")
    if [[ "${SELINUX_STATUS}" == "Disabled" ]]; then
        log_warn "SELinux が無効です。スキップします。"
    elif ! command -v semanage &>/dev/null; then
        log_warn "semanage コマンドが見つかりません。スキップします。"
    else
        log_info "--remove-selinux-port が指定されました。SELinux ポート設定を削除します..."
        # TCP 514 の削除
        if semanage port -l | grep -q "${SELINUX_PORT_TYPE}.*tcp.*\b${SYSLOG_PORT}\b"; then
            run_cmd semanage port -d -t "${SELINUX_PORT_TYPE}" -p tcp "${SYSLOG_PORT}"
            log_ok "TCP ${SYSLOG_PORT} を ${SELINUX_PORT_TYPE} から削除しました。"
        else
            log_info "TCP ${SYSLOG_PORT} は ${SELINUX_PORT_TYPE} に登録されていません。スキップします。"
        fi
        # UDP 514 の削除
        if semanage port -l | grep -q "${SELINUX_PORT_TYPE}.*udp.*\b${SYSLOG_PORT}\b"; then
            run_cmd semanage port -d -t "${SELINUX_PORT_TYPE}" -p udp "${SYSLOG_PORT}"
            log_ok "UDP ${SYSLOG_PORT} を ${SELINUX_PORT_TYPE} から削除しました。"
        else
            log_info "UDP ${SYSLOG_PORT} は ${SELINUX_PORT_TYPE} に登録されていません。スキップします。"
        fi
    fi
else
    log_info "SELinux ポート設定は削除しません（--remove-selinux-port 未指定）。"
    log_info "削除する場合は: sudo $0 --remove-selinux-port"
fi

# =============================================================================
# ステップ 6: 最終確認情報の表示
# =============================================================================
echo ""
log_info "=========================================="
log_info " ロールバック完了 - 最終確認情報"
log_info "=========================================="

log_info "--- rsyslog ステータス ---"
if [[ "${DRY_RUN}" == false ]]; then
    systemctl status rsyslog --no-pager -l | head -10 || true
fi

log_info "--- firewalld 設定 ---"
if [[ "${DRY_RUN}" == false ]]; then
    firewall-cmd --list-all || true
fi

log_info "--- SELinux ステータス ---"
getenforce 2>/dev/null || echo "Unknown"

echo ""
log_warn "=========================================="
log_warn " 注意: 以下のデータは削除していません"
log_warn "=========================================="
log_warn "  - /var/log/syslog-appliance/raw/  （受信済みログ）"
log_warn "  - /var/log/syslog-appliance/.backup/  （バックアップファイル）"
log_warn "  - /etc/syslog-appliance/  （設定雛形ファイル）"
log_warn "  必要に応じて手動で削除してください。"
echo ""
log_ok "=========================================="
log_ok " MVP 0 ロールバックが完了しました。"
log_ok "=========================================="
echo ""
