#!/usr/bin/env bash
# =============================================================================
# check-disk-usage.sh
#
# 概要:
#   ログ保存ディスク（/var/log のマウントポイント）の使用率を監視し、
#   閾値を超えた場合に警告を出力します。
#
# 出力先:
#   A. ログファイル: /var/log/syslog-appliance/alerts.log（JSON Lines 形式）
#   B. メール送信: appliance.conf で mail_enabled=true の場合のみ
#                  （MVP 0 強化フェーズでは枠のみ、実際の送信は MVP 1 以降で実装）
#   C. 通知ファイル: /var/lib/syslog-appliance/notifications/disk-usage.json
#                   （Web UI がポーリングして警告バナーを表示することを想定）
#
# 実行例:
#   sudo /opt/syslog-appliance/scripts/check-disk-usage.sh
#   sudo /opt/syslog-appliance/scripts/check-disk-usage.sh --dry-run
#   sudo /opt/syslog-appliance/scripts/check-disk-usage.sh --threshold-warn 70
# =============================================================================
set -euo pipefail

# =============================================================================
# 定数・パス定義
# =============================================================================

# 監視対象: /var/log ディレクトリが属するマウントポイントを特定するための基点パス
MONITOR_DIR="/var/log"

# 警告ログの出力先（A: JSON Lines 形式で追記）
ALERT_LOG="/var/log/syslog-appliance/alerts.log"

# 通知ファイルの配置ディレクトリとファイルパス（C: 常に最新1件を上書き）
NOTIFICATION_DIR="/var/lib/syslog-appliance/notifications"
NOTIFICATION_FILE="${NOTIFICATION_DIR}/disk-usage.json"

# アプライアンス設定ファイル（メール通知設定の読み込みに使用）
APPLIANCE_CONF="/etc/syslog-appliance/appliance.conf"

# =============================================================================
# フラグ・閾値のデフォルト値初期化
# =============================================================================
DRY_RUN=false
THRESHOLD_WARN=80
THRESHOLD_CRITICAL=90

# =============================================================================
# カラー出力設定
# =============================================================================
# tty に出力している場合のみ ANSI カラーコードを使用する
# ログファイルやパイプに色コードが混入しないようにするための判定
if tty -s 2>/dev/null; then
    C_RESET='\033[0m'
    C_INFO='\033[0;36m'   # シアン
    C_OK='\033[0;32m'     # 緑
    C_WARN='\033[0;33m'   # 黄
    C_ERROR='\033[0;31m'  # 赤
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

# =============================================================================
# ヘルプ表示
# =============================================================================
show_help() {
    cat <<EOF
使い方:
  sudo $0 [オプション]

オプション:
  --dry-run
      実際のファイル書き込みは行わず、標準出力への表示のみ行う。
      動作確認や事前テストに使用してください。

  --threshold-warn <PERCENT>
      WARN 閾値を設定します（デフォルト: ${THRESHOLD_WARN}）。
      指定したパーセンテージ以上で WARN 警告を出力します。

  --threshold-critical <PERCENT>
      CRITICAL 閾値を設定します（デフォルト: ${THRESHOLD_CRITICAL}）。
      指定したパーセンテージ以上で CRITICAL 警告を出力します。

  --help, -h
      このヘルプを表示して終了する。

実行例:
  sudo $0
  sudo $0 --dry-run
  sudo $0 --threshold-warn 70 --threshold-critical 85
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
        --threshold-warn)
            if [[ -z "${2:-}" ]]; then
                log_error "--threshold-warn には数値（%）を指定してください。"
                exit 1
            fi
            THRESHOLD_WARN="$2"
            shift 2
            ;;
        --threshold-critical)
            if [[ -z "${2:-}" ]]; then
                log_error "--threshold-critical には数値（%）を指定してください。"
                exit 1
            fi
            THRESHOLD_CRITICAL="$2"
            shift 2
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
# appliance.conf から設定値を読み込む関数
# =============================================================================
# INI 形式のファイルから指定セクション・キーの値を取得する。
# 設定ファイルが存在しない、またはキーが未設定の場合はデフォルト値を返す。
#
# 引数:
#   $1: セクション名（例: notification）
#   $2: キー名（例: mail_enabled）
#   $3: デフォルト値
read_conf_value() {
    local section="$1"
    local key="$2"
    local default_val="$3"

    # 設定ファイルが存在しない場合はデフォルト値を返す
    if [[ ! -f "${APPLIANCE_CONF}" ]]; then
        echo "${default_val}"
        return
    fi

    # awk で INI 形式のファイルを解析し、指定セクション・キーの値を取得する
    # index() で最初の "=" 位置を求めることで、値に "=" を含む場合にも対応する
    local value
    value=$(awk \
        -v target_section="${section}" \
        -v target_key="${key}" \
        'BEGIN { in_target = 0 }
        /^\[/ {
            name = substr($0, 2, length($0) - 2)
            gsub(/[[:space:]]/, "", name)
            in_target = (name == target_section)
            next
        }
        /^[[:space:]]*(#|$)/ { next }
        in_target {
            n = index($0, "=")
            if (n > 0) {
                k = substr($0, 1, n - 1)
                v = substr($0, n + 1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
                sub(/#.*$/, "", v)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
                if (k == target_key) { print v; exit }
            }
        }' "${APPLIANCE_CONF}")

    # 値が空の場合はデフォルト値を返す
    echo "${value:-${default_val}}"
}

# =============================================================================
# アラートログへの書き込み関数（出力先 A）
# =============================================================================
# JSON Lines 形式で /var/log/syslog-appliance/alerts.log に1行追記する。
#
# 引数:
#   $1: level（WARN または CRITICAL）
#   $2: usage_percent（使用率の整数値）
#   $3: mountpoint（マウントポイントのパス）
#   $4: message（警告メッセージ）
write_alert_log() {
    local level="$1"
    local usage_percent="$2"
    local mountpoint="$3"
    local message="$4"

    # ISO 8601 形式（+HH:MM タイムゾーン付き）でタイムスタンプを生成する
    local timestamp
    timestamp=$(date +"%Y-%m-%dT%H:%M:%S%:z")

    # JSON Lines 形式の1行を構築する
    # printf の %s/%d 形式を使うことで、変数内の特殊文字（%等）を誤解釈しない
    local json_line
    json_line=$(printf \
        '{"timestamp":"%s","level":"%s","type":"disk_usage","mountpoint":"%s","usage_percent":%d,"message":"%s"}' \
        "${timestamp}" "${level}" "${mountpoint}" "${usage_percent}" "${message}")

    if [[ "${DRY_RUN}" == true ]]; then
        log_info "[DRY-RUN] アラートログへの書き込みをスキップ:"
        log_info "  ${json_line}"
        return
    fi

    # アラートログの親ディレクトリが存在しない場合は作成する
    local alert_dir
    alert_dir=$(dirname "${ALERT_LOG}")
    if [[ ! -d "${alert_dir}" ]]; then
        mkdir -p "${alert_dir}"
        chmod 0750 "${alert_dir}"
        chown root:root "${alert_dir}"
    fi

    echo "${json_line}" >> "${ALERT_LOG}"
}

# =============================================================================
# メール通知関数（出力先 B）
# =============================================================================
# appliance.conf の [notification] セクションを読み込み、
# mail_enabled=true の場合のみメール送信を試みる。
#
# 注意: MVP 0 強化フェーズでは実際の送信は実装しない。
#       送信ロジック部分に「ここでメール送信処理を行う」コメントのみ記述する。
#       実際のメール送信（sendmail/mail コマンドの呼び出し）は MVP 1 以降で実装予定。
#
# 引数:
#   $1: level（WARN または CRITICAL）
#   $2: usage_percent（使用率の整数値）
#   $3: mountpoint（マウントポイントのパス）
#   $4: message（警告メッセージ）
send_mail_notification() {
    local level="$1"
    local usage_percent="$2"
    local mountpoint="$3"
    local message="$4"

    # appliance.conf から mail_enabled を読み込む（デフォルト: false）
    local mail_enabled
    mail_enabled=$(read_conf_value "notification" "mail_enabled" "false")

    # メール通知が無効の場合は何もしない
    if [[ "${mail_enabled}" != "true" ]]; then
        return
    fi

    # SMTP 設定を appliance.conf から読み込む
    local smtp_server smtp_port smtp_from smtp_to
    smtp_server=$(read_conf_value "notification" "smtp_server" "")
    smtp_port=$(read_conf_value "notification" "smtp_port" "25")
    smtp_from=$(read_conf_value "notification" "smtp_from" "")
    smtp_to=$(read_conf_value "notification" "smtp_to" "")

    # SMTP 必須項目が未入力の場合は、alerts.log に警告を書いてスキップする
    # エラーで停止させず、後続の通知ファイル更新（出力先 C）は継続する
    if [[ -z "${smtp_server}" || -z "${smtp_from}" || -z "${smtp_to}" ]]; then
        local smtp_warn_msg="メール送信設定が未入力のためスキップします（smtp_server/smtp_from/smtp_to を appliance.conf で確認してください）"
        write_alert_log "WARN" "${usage_percent}" "${mountpoint}" "${smtp_warn_msg}"
        log_warn "[mail] ${smtp_warn_msg}"
        return
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        log_info "[DRY-RUN] メール送信をスキップ: level=${level}, smtp_to=${smtp_to}"
        return
    fi

    # ここでメール送信処理を行う（MVP 1 以降で実装）
    # 実装予定: sendmail または mail コマンドでアラートメールを送信する
    # 例（MVP 1 で実装）:
    #   SUBJECT="[syslog-appliance] ディスク使用率 ${level}: ${usage_percent}%"
    #   printf "Subject: %s\n\n%s\n" "${SUBJECT}" "${message}" \
    #       | sendmail -f "${smtp_from}" "${smtp_to}"
    log_info "[mail] メール送信処理（MVP 1 以降で実装予定）: level=${level}, smtp_to=${smtp_to}"
}

# =============================================================================
# 通知ファイル更新関数（出力先 C）
# =============================================================================
# /var/lib/syslog-appliance/notifications/disk-usage.json を常に最新の1件で上書きする。
# Web UI がこのファイルをポーリングして、ホーム画面に警告バナーを表示することを想定。
#
# 引数:
#   $1: status（ok / warning / critical）
#   $2: usage_percent（使用率の整数値）
#   $3: message（状態メッセージ）
write_notification_file() {
    local status="$1"
    local usage_percent="$2"
    local message="$3"

    local timestamp
    timestamp=$(date +"%Y-%m-%dT%H:%M:%S%:z")

    # JSON 形式でコンテンツを構築する（インデント付きで可読性を確保）
    local json_content
    json_content=$(printf '{
  "last_check": "%s",
  "status": "%s",
  "current_usage_percent": %d,
  "threshold_warn": %d,
  "threshold_critical": %d,
  "message": "%s"
}' \
        "${timestamp}" "${status}" "${usage_percent}" \
        "${THRESHOLD_WARN}" "${THRESHOLD_CRITICAL}" "${message}")

    if [[ "${DRY_RUN}" == true ]]; then
        log_info "[DRY-RUN] 通知ファイルへの書き込みをスキップ:"
        echo "${json_content}"
        return
    fi

    # 通知ファイルの親ディレクトリが存在しない場合は作成する
    if [[ ! -d "${NOTIFICATION_DIR}" ]]; then
        mkdir -p "${NOTIFICATION_DIR}"
        chmod 0750 "${NOTIFICATION_DIR}"
        chown root:root "${NOTIFICATION_DIR}"
    fi

    # 常に最新の1件で上書きする（append ではなく上書き）
    echo "${json_content}" > "${NOTIFICATION_FILE}"
}

# =============================================================================
# メイン処理
# =============================================================================
log_info "ディスク使用率の確認を開始します..."
[[ "${DRY_RUN}" == true ]] && log_warn "DRY-RUN モード: ファイルへの書き込みは行いません。"

# ---------------------------------------------------------------------------
# ディスク使用率の取得
# ---------------------------------------------------------------------------
# df -P（POSIX 形式）で /var/log が属するマウントポイントのディスク使用率を取得する。
# 出力の NR==2 行のフォーマット:
#   ファイルシステム  1024-ブロック  使用済み  利用可能  使用率%  マウントポイント
# $5 が使用率（例: "85%"）、$6 がマウントポイント（例: "/"）
#
# 事前に変数を空文字列で初期化し、取得失敗時に未定義エラーが発生しないようにする
USAGE_PERCENT=""
MOUNTPOINT=""
read -r USAGE_PERCENT MOUNTPOINT < <(
    df -P "${MONITOR_DIR}" \
    | awk 'NR==2 { gsub(/%/, "", $5); print $5, $6 }'
) || true

# 取得値の検証: 使用率が整数でない場合はエラーで終了する
if [[ ! "${USAGE_PERCENT}" =~ ^[0-9]+$ ]]; then
    log_error "ディスク使用率を正常に取得できませんでした: '${USAGE_PERCENT}'"
    log_error "  df -P ${MONITOR_DIR} の出力を確認してください。"
    exit 1
fi

log_info "監視対象: ${MONITOR_DIR}（マウントポイント: ${MOUNTPOINT}）"
log_info "ディスク使用率: ${USAGE_PERCENT}%（WARN 閾値: ${THRESHOLD_WARN}%、CRITICAL 閾値: ${THRESHOLD_CRITICAL}%）"

# ---------------------------------------------------------------------------
# 閾値との比較・警告出力
# ---------------------------------------------------------------------------
# 優先度: CRITICAL > WARN > 正常
# CRITICAL の場合は WARN メッセージは出力しない（上位レベルのみ）

if [[ "${USAGE_PERCENT}" -ge "${THRESHOLD_CRITICAL}" ]]; then
    # CRITICAL 閾値以上: 3つすべての出力先に警告を書き出す
    ALERT_MSG="ディスク使用率が ${THRESHOLD_CRITICAL}% を超えました"
    log_error "CRITICAL: ${ALERT_MSG}（現在: ${USAGE_PERCENT}%）"

    write_alert_log        "CRITICAL" "${USAGE_PERCENT}" "${MOUNTPOINT}" "${ALERT_MSG}"
    send_mail_notification "CRITICAL" "${USAGE_PERCENT}" "${MOUNTPOINT}" "${ALERT_MSG}"
    write_notification_file "critical" "${USAGE_PERCENT}" "${ALERT_MSG}"

elif [[ "${USAGE_PERCENT}" -ge "${THRESHOLD_WARN}" ]]; then
    # WARN 閾値以上: 3つすべての出力先に警告を書き出す
    ALERT_MSG="ディスク使用率が ${THRESHOLD_WARN}% を超えました"
    log_warn "WARN: ${ALERT_MSG}（現在: ${USAGE_PERCENT}%）"

    write_alert_log        "WARN" "${USAGE_PERCENT}" "${MOUNTPOINT}" "${ALERT_MSG}"
    send_mail_notification "WARN" "${USAGE_PERCENT}" "${MOUNTPOINT}" "${ALERT_MSG}"
    write_notification_file "warning" "${USAGE_PERCENT}" "${ALERT_MSG}"

else
    # 正常範囲: 通知ファイル（C）のみ更新する
    # アラートログ（A）やメール（B）には書き出さない（ノイズを避けるため）
    ALERT_MSG="ディスク使用率は正常範囲内です"
    log_ok "${ALERT_MSG}（現在: ${USAGE_PERCENT}%）"
    write_notification_file "ok" "${USAGE_PERCENT}" "${ALERT_MSG}"
fi

log_info "ディスク使用率の確認が完了しました。"
