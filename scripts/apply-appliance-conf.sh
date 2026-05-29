#!/usr/bin/env bash
# =============================================================================
# apply-appliance-conf.sh
#
# 概要:
#   /etc/syslog-appliance/appliance.conf の [receive] セクションを読み込み、
#   allowed_sources の設定に基づいて firewalld の受信元制限を適用します。
#
#   動作:
#     - allowed_sources が空欄 → 全許可（rich rule を削除し、ポート許可のみ）
#     - allowed_sources に CIDR 指定 → rich rule で送信元を制限し、
#                                      ポート許可（--add-port）は削除
#
# 実行例:
#   sudo /opt/syslog-appliance/scripts/apply-appliance-conf.sh
#   sudo /opt/syslog-appliance/scripts/apply-appliance-conf.sh --dry-run
#   sudo /opt/syslog-appliance/scripts/apply-appliance-conf.sh --help
#
# 戻し方:
#   sudo firewall-cmd --list-all で現在の設定を確認し、
#   必要に応じて手動で rich rule / ポート設定を変更してください。
#   または setup-mvp0.sh / rollback-mvp0.sh で設定を再適用・初期化できます。
# =============================================================================
set -euo pipefail

# =============================================================================
# 定数・パス定義
# =============================================================================
APPLIANCE_CONF="/etc/syslog-appliance/appliance.conf"
SYSLOG_PORT="514"
SYSLOG_PROTO_UDP="udp"
SYSLOG_PROTO_TCP="tcp"

# =============================================================================
# フラグ初期化
# =============================================================================
DRY_RUN=false

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
  --dry-run
      実際の変更は行わず、実行予定のコマンドを表示するだけ。
      事前確認に使用してください。

  --help
      このヘルプを表示して終了する。

設定ファイル:
  ${APPLIANCE_CONF} の [receive] セクションにある
  allowed_sources を読み込み、firewalld に適用します。

  例（全許可）:
    [receive]
    allowed_sources =

  例（送信元制限）:
    [receive]
    allowed_sources = 192.168.1.0/24,10.0.0.0/8

戻し方:
  sudo firewall-cmd --list-all で現在の設定を確認し、
  必要に応じて手動で設定を変更してください。
EOF
}

# =============================================================================
# 引数解析
# =============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
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
log_info " apply-appliance-conf.sh 開始"
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
# ステップ 1: 設定ファイルの読み込み
# =============================================================================
log_info "[Step 1] 設定ファイルを読み込み..."

if [[ ! -f "${APPLIANCE_CONF}" ]]; then
    log_warn "設定ファイルが見つかりません: ${APPLIANCE_CONF}"
    log_warn "appliance.conf.example をコピーして設定してください:"
    log_warn "  sudo cp /etc/syslog-appliance/appliance.conf.example ${APPLIANCE_CONF}"
    exit 1
fi

# INI 形式の [receive] セクションから allowed_sources を取得する。
# awk で [receive] セクションに入ったら該当キーを抽出し、= 以降を取得する。
# 行末コメント（# 以降）と前後の空白を除去する。
ALLOWED_SOURCES=$(awk '
    /^\[receive\]/ { in_section=1; next }
    /^\[/          { in_section=0 }
    in_section && /^allowed_sources[[:space:]]*=/ {
        sub(/^allowed_sources[[:space:]]*=[[:space:]]*/, "")
        sub(/[[:space:]]*#.*$/, "")
        sub(/^[[:space:]]+/, "")
        sub(/[[:space:]]+$/, "")
        print
        exit
    }
' "${APPLIANCE_CONF}")

log_ok "設定ファイル読み込み完了: ${APPLIANCE_CONF}"
if [[ -z "${ALLOWED_SOURCES}" ]]; then
    log_info "allowed_sources: （空欄）→ 全許可モード"
else
    log_info "allowed_sources: ${ALLOWED_SOURCES}"
fi

# =============================================================================
# ステップ 2: 現在の firewalld 設定を確認
# =============================================================================
log_info "[Step 2] 現在の firewalld 設定を確認..."

log_info "  現在のポート許可:"
# port 514/ に一致するものだけ表示する（一致しない場合は「なし」と表示）
CURRENT_PORTS=$(firewall-cmd --list-ports --permanent 2>/dev/null \
    | tr ' ' '\n' \
    | grep "^${SYSLOG_PORT}/" \
    || true)
if [[ -z "${CURRENT_PORTS}" ]]; then
    log_info "    （514/udp および 514/tcp は未許可）"
else
    while IFS= read -r p; do log_info "    ${p}"; done <<< "${CURRENT_PORTS}"
fi

log_info "  現在の Rich rule:"
CURRENT_RICH_RULES=$(firewall-cmd --list-rich-rules --permanent 2>/dev/null || true)
if [[ -z "${CURRENT_RICH_RULES}" ]]; then
    log_info "    （なし）"
else
    while IFS= read -r rule; do
        log_info "    ${rule}"
    done <<< "${CURRENT_RICH_RULES}"
fi

# =============================================================================
# ステップ 3: 既存の 514 関連 rich rule を削除
# =============================================================================
log_info "[Step 3] 既存の 514 関連 rich rule を削除..."

if [[ "${DRY_RUN}" == false ]]; then
    while IFS= read -r rule; do
        [[ -z "${rule}" ]] && continue
        if [[ "${rule}" =~ port.*port=\"514\" ]]; then
            log_info "  削除対象: ${rule}"
            firewall-cmd --permanent --remove-rich-rule="${rule}" \
                && log_ok "  削除完了。" \
                || log_warn "  削除に失敗しました（既に削除済みの可能性あり）。"
        fi
    done <<< "$(firewall-cmd --list-rich-rules --permanent 2>/dev/null || true)"
    log_ok "514 関連 rich rule の削除処理が完了しました。"
else
    log_warn "[DRY-RUN] Rich rule の削除はスキップします。"
fi

# =============================================================================
# ステップ 4: firewalld にルールを適用
# =============================================================================
log_info "[Step 4] firewalld にルールを適用..."

if [[ -z "${ALLOWED_SOURCES}" ]]; then
    # --------------------------------------------------
    # 全許可モード: ポート許可のみ（rich rule は不使用）
    # --------------------------------------------------
    log_info "全送信元許可モードで設定します。"

    for PROTO in "${SYSLOG_PROTO_UDP}" "${SYSLOG_PROTO_TCP}"; do
        if [[ "${DRY_RUN}" == false ]]; then
            if firewall-cmd --query-port="${SYSLOG_PORT}/${PROTO}" --permanent &>/dev/null; then
                log_ok "  ${PROTO^^} ${SYSLOG_PORT} は既に許可済みです。"
            else
                firewall-cmd --permanent --add-port="${SYSLOG_PORT}/${PROTO}"
                log_ok "  ${PROTO^^} ${SYSLOG_PORT} を許可しました。"
            fi
        else
            echo -e "${C_WARN}[DRY-RUN]${C_RESET} firewall-cmd --permanent --add-port=${SYSLOG_PORT}/${PROTO}"
        fi
    done

else
    # --------------------------------------------------
    # 送信元制限モード: rich rule で CIDR を制限
    # --------------------------------------------------
    log_info "送信元制限モードで設定します: ${ALLOWED_SOURCES}"

    # 既存のポート許可（--add-port で追加されたもの）を削除する
    # rich rule が有効な場合はポート許可が上書きされてしまうため、先に削除する
    log_info "  既存のポート許可を削除..."
    for PROTO in "${SYSLOG_PROTO_UDP}" "${SYSLOG_PROTO_TCP}"; do
        if [[ "${DRY_RUN}" == false ]]; then
            if firewall-cmd --query-port="${SYSLOG_PORT}/${PROTO}" --permanent &>/dev/null; then
                firewall-cmd --permanent --remove-port="${SYSLOG_PORT}/${PROTO}"
                log_ok "  ${PROTO^^} ${SYSLOG_PORT} のポート許可を削除しました。"
            else
                log_info "  ${PROTO^^} ${SYSLOG_PORT} のポート許可はありません。スキップします。"
            fi
        else
            echo -e "${C_WARN}[DRY-RUN]${C_RESET} firewall-cmd --permanent --remove-port=${SYSLOG_PORT}/${PROTO}"
        fi
    done

    # 各 CIDR に対して rich rule を追加する
    IFS=',' read -ra CIDRS <<< "${ALLOWED_SOURCES}"
    for CIDR in "${CIDRS[@]}"; do
        CIDR="${CIDR// /}"  # 前後のスペースを除去
        [[ -z "${CIDR}" ]] && continue
        log_info "  Rich rule を追加: ${CIDR} からの ${SYSLOG_PORT}/udp, ${SYSLOG_PORT}/tcp を許可..."
        run_cmd firewall-cmd --permanent \
            --add-rich-rule="rule family=\"ipv4\" source address=\"${CIDR}\" port port=\"${SYSLOG_PORT}\" protocol=\"${SYSLOG_PROTO_UDP}\" accept"
        run_cmd firewall-cmd --permanent \
            --add-rich-rule="rule family=\"ipv4\" source address=\"${CIDR}\" port port=\"${SYSLOG_PORT}\" protocol=\"${SYSLOG_PROTO_TCP}\" accept"
        log_ok "  Rich rule 追加: ${CIDR} -> ${SYSLOG_PORT}/udp, ${SYSLOG_PORT}/tcp"
    done
fi

# firewalld をリロードして設定を反映する
run_cmd firewall-cmd --reload
log_ok "firewalld をリロードしました。"

# =============================================================================
# ステップ 5: 適用後の firewalld 設定を表示
# =============================================================================
echo ""
log_info "=========================================="
log_info " 適用後の firewalld 設定"
log_info "=========================================="
if [[ "${DRY_RUN}" == false ]]; then
    firewall-cmd --list-all || true
else
    log_warn "[DRY-RUN] 適用後の設定表示をスキップします。"
fi

echo ""
log_ok "=========================================="
log_ok " apply-appliance-conf.sh 完了"
log_ok "=========================================="
echo ""
