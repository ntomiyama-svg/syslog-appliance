#!/usr/bin/env bash
# =============================================================================
# rollback-mvp0.sh
#
# 概要:
#   syslog-appliance MVP 0 のロールバックスクリプト。
#   setup-mvp0.sh で行った変更を取り消します。
#
#   以下の作業を自動化します:
#     1. ディスク使用量監視タイマーの無効化（ファイル移動）
#     2. rsyslog 設定ファイルの削除（バックアップとして移動）
#     3. logrotate 設定ファイルの削除（バックアップとして移動）
#     4. rsyslog 構文チェック
#     5. rsyslog 再起動
#     6. firewalld からの 514/udp, 514/tcp 許可を削除
#     7. （オプション）SELinux ポート設定の削除
#     8. 最終確認情報表示
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
RSYSLOG_STATS_CONF_DEST="/etc/rsyslog.d/11-syslog-appliance-stats.conf"
LOGROTATE_CONF_DEST="/etc/logrotate.d/syslog-appliance"
BACKUP_DIR="/var/log/syslog-appliance/.backup"

# ディスク使用量監視スクリプト関連パス
DISK_CHECK_SCRIPT_DEST="/opt/syslog-appliance/scripts/check-disk-usage.sh"
# 受信元制限スクリプト関連パス（T2）
APPLY_CONF_SCRIPT_DEST="/opt/syslog-appliance/scripts/apply-appliance-conf.sh"
# rsyslog 自動回復 drop-in 関連パス（T8）
RSYSLOG_RESTART_DROPIN_DIR="/etc/systemd/system/rsyslog.service.d"
RSYSLOG_RESTART_CONF_DEST="${RSYSLOG_RESTART_DROPIN_DIR}/restart.conf"
DISK_CHECK_SERVICE_DEST="/etc/systemd/system/syslog-appliance-disk-check.service"
DISK_CHECK_TIMER_DEST="/etc/systemd/system/syslog-appliance-disk-check.timer"
DISK_CHECK_TIMER_NAME="syslog-appliance-disk-check.timer"
NOTIFICATION_DATA_DIR="/var/lib/syslog-appliance/notifications"

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
# ステップ 1: ディスク使用量監視タイマーの無効化とファイルの移動
# =============================================================================
log_info "[Step 1] ディスク使用量監視タイマーを無効化..."

# バックアップディレクトリを事前に作成しておく
run_cmd mkdir -p "${BACKUP_DIR}"

# タイマーユニットが存在する場合のみ無効化する（冪等処理）
if [[ "${DRY_RUN}" == true ]]; then
    echo -e "${C_WARN}[DRY-RUN]${C_RESET} systemctl disable --now ${DISK_CHECK_TIMER_NAME}"
elif systemctl list-unit-files --type=timer 2>/dev/null | grep -q "${DISK_CHECK_TIMER_NAME}"; then
    systemctl disable --now "${DISK_CHECK_TIMER_NAME}" && \
        log_ok "タイマー ${DISK_CHECK_TIMER_NAME} を無効化しました。" || \
        log_warn "タイマーの無効化に失敗しました（既に停止中の可能性あり）。"
else
    log_info "タイマー ${DISK_CHECK_TIMER_NAME} が見つかりません。スキップします。"
fi

# systemd デーモンをリロードしてユニットキャッシュを更新する
run_cmd systemctl daemon-reload

# systemd ユニットファイルをバックアップとして移動する
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
for SVC_FILE in "${DISK_CHECK_TIMER_DEST}" "${DISK_CHECK_SERVICE_DEST}"; do
    if [[ -f "${SVC_FILE}" ]]; then
        REMOVED_FILE="${BACKUP_DIR}/$(basename "${SVC_FILE}").removed.${TIMESTAMP}"
        run_cmd mv "${SVC_FILE}" "${REMOVED_FILE}"
        log_ok "$(basename "${SVC_FILE}") を移動: ${REMOVED_FILE}"
    else
        log_info "ファイルが見つかりません: ${SVC_FILE}（スキップ）"
    fi
done

# 監視スクリプト本体をバックアップとして移動する
if [[ -f "${DISK_CHECK_SCRIPT_DEST}" ]]; then
    REMOVED_FILE="${BACKUP_DIR}/check-disk-usage.sh.removed.${TIMESTAMP}"
    run_cmd mv "${DISK_CHECK_SCRIPT_DEST}" "${REMOVED_FILE}"
    log_ok "check-disk-usage.sh を移動: ${REMOVED_FILE}"
else
    log_info "ファイルが見つかりません: ${DISK_CHECK_SCRIPT_DEST}（スキップ）"
fi

# 通知ファイル（/var/lib/syslog-appliance/notifications/）は削除しない
# Web UI や外部システムが参照している可能性があるため、データの保全を優先する
log_info "通知ファイル（${NOTIFICATION_DATA_DIR}/）はデータ保全のため削除しません。"

# =============================================================================
# ステップ 2: rsyslog 設定ファイルの削除（バックアップとして移動）
# =============================================================================
log_info "[Step 2] rsyslog 設定ファイルを削除（バックアップとして移動）..."

# メイン設定ファイル（10-）の移動
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

# 統計設定ファイル（11-）の移動
if [[ -f "${RSYSLOG_STATS_CONF_DEST}" ]]; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    REMOVED_FILE="${BACKUP_DIR}/11-syslog-appliance-stats.conf.removed.${TIMESTAMP}"
    run_cmd mkdir -p "${BACKUP_DIR}"
    run_cmd mv "${RSYSLOG_STATS_CONF_DEST}" "${REMOVED_FILE}"
    log_ok "統計設定ファイルを移動: ${RSYSLOG_STATS_CONF_DEST} -> ${REMOVED_FILE}"
else
    log_info "rsyslog 統計設定ファイルが見つかりません: ${RSYSLOG_STATS_CONF_DEST}（スキップ）"
fi

# apply-appliance-conf.sh の移動
# 注意: apply-appliance-conf.sh で設定した firewalld の rich rule は
#       ここでは削除しない。rich rule は appliance.conf の設定を反映した
#       運用設定であり、ロールバック後も firewalld の設定として残す。
#       必要な場合は管理者が手動で削除すること: firewall-cmd --list-rich-rules
if [[ -f "${APPLY_CONF_SCRIPT_DEST}" ]]; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    REMOVED_FILE="${BACKUP_DIR}/apply-appliance-conf.sh.removed.${TIMESTAMP}"
    run_cmd mv "${APPLY_CONF_SCRIPT_DEST}" "${REMOVED_FILE}"
    log_ok "apply-appliance-conf.sh を移動: ${APPLY_CONF_SCRIPT_DEST} -> ${REMOVED_FILE}"
else
    log_info "ファイルが見つかりません: ${APPLY_CONF_SCRIPT_DEST}（スキップ）"
fi

# rsyslog 自動回復 drop-in（restart.conf）の移動
if [[ -f "${RSYSLOG_RESTART_CONF_DEST}" ]]; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    REMOVED_FILE="${BACKUP_DIR}/rsyslog-restart.conf.removed.${TIMESTAMP}"
    run_cmd mv "${RSYSLOG_RESTART_CONF_DEST}" "${REMOVED_FILE}"
    log_ok "rsyslog-restart.conf を移動: ${RSYSLOG_RESTART_CONF_DEST} -> ${REMOVED_FILE}"

    # 親ディレクトリが空になった場合のみ削除する
    if [[ "${DRY_RUN}" == false ]]; then
        if [[ -d "${RSYSLOG_RESTART_DROPIN_DIR}" ]] && \
           [[ -z "$(ls -A "${RSYSLOG_RESTART_DROPIN_DIR}" 2>/dev/null)" ]]; then
            rmdir "${RSYSLOG_RESTART_DROPIN_DIR}"
            log_ok "空になったディレクトリを削除: ${RSYSLOG_RESTART_DROPIN_DIR}"
        fi
    else
        echo -e "${C_WARN}[DRY-RUN]${C_RESET} rmdir ${RSYSLOG_RESTART_DROPIN_DIR} （空の場合のみ）"
    fi
else
    log_info "ファイルが見つかりません: ${RSYSLOG_RESTART_CONF_DEST}（スキップ）"
fi

# drop-in を削除したので daemon-reload で systemd に変更を認識させる
run_cmd systemctl daemon-reload
log_ok "systemctl daemon-reload を実行しました（drop-in 削除反映）。"

# =============================================================================
# ステップ 3: logrotate 設定ファイルの削除（バックアップとして移動）
# =============================================================================
log_info "[Step 3] logrotate 設定ファイルを削除（バックアップとして移動）..."
if [[ -f "${LOGROTATE_CONF_DEST}" ]]; then
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    REMOVED_FILE="${BACKUP_DIR}/syslog-appliance.logrotate.removed.${TIMESTAMP}"
    run_cmd mkdir -p "${BACKUP_DIR}"
    run_cmd mv "${LOGROTATE_CONF_DEST}" "${REMOVED_FILE}"
    log_ok "logrotate 設定ファイルを移動: ${LOGROTATE_CONF_DEST} -> ${REMOVED_FILE}"
else
    log_info "logrotate 設定ファイルが見つかりません: ${LOGROTATE_CONF_DEST}"
    log_info "既にロールバック済みか、手動で削除された可能性があります。"
fi

# =============================================================================
# ステップ 4: rsyslog 構文チェック
# =============================================================================
log_info "[Step 4] rsyslog 設定の構文チェック..."
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
# ステップ 5: rsyslog 再起動
# =============================================================================
log_info "[Step 5] rsyslog を再起動..."
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
# ステップ 6: firewalld から 514/udp, 514/tcp の許可を削除
# =============================================================================
log_info "[Step 6] firewalld の 514/udp, 514/tcp 許可を削除..."

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
# ステップ 7: SELinux ポート設定の削除（オプション）
# =============================================================================
log_info "[Step 7] SELinux ポート設定の確認..."
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
# ステップ 8: 最終確認情報の表示
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
log_warn "  - /var/log/syslog-appliance/stats/  （rsyslog 統計ログ・運用上の証跡として保持）"
log_warn "  - /var/log/syslog-appliance/.backup/  （バックアップファイル）"
log_warn "  - /etc/syslog-appliance/  （設定雛形ファイル）"
log_warn "  - /var/lib/syslog-appliance/notifications/  （通知ファイル）"
log_warn "  必要に応じて手動で削除してください。"
log_warn ""
log_warn "  また、apply-appliance-conf.sh で設定した firewalld の rich rule は"
log_warn "  削除していません。手動で削除する場合は以下を実行してください:"
log_warn "    sudo firewall-cmd --list-rich-rules"
log_warn "    sudo firewall-cmd --permanent --remove-rich-rule='<rule>'"
log_warn "    sudo firewall-cmd --reload"
echo ""
log_ok "=========================================="
log_ok " MVP 0 ロールバックが完了しました。"
log_ok "=========================================="
echo ""
