#!/usr/bin/env bash
# rollback-mvp1-backend.sh
# MVP 1.0 バックエンドのロールバックスクリプト
#
# 使用方法:
#   sudo bash rollback-mvp1-backend.sh
#   sudo bash rollback-mvp1-backend.sh --dry-run
#   sudo bash rollback-mvp1-backend.sh --purge   # DB・ユーザーも削除
#   sudo bash rollback-mvp1-backend.sh --help
#
# ⚠️  このスクリプトは root 権限が必要です
# ⚠️  --purge を指定するとデータ（DB）も削除されます。慎重に使用してください。

set -euo pipefail

# ── カラー定義 ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${BOLD}── $* ──${NC}"; }

# ── 設定値 ──────────────────────────────────────────────────────────────────────
APP_USER="syslog-appliance"
APP_HOME="/opt/syslog-appliance"
BACKEND_DIR="${APP_HOME}/backend"
DATA_DIR="/var/lib/syslog-appliance"
CONF_DIR="/etc/syslog-appliance"
BACKEND_ENV="${CONF_DIR}/backend.env"
SYSTEMD_UNIT_NAME="syslog-appliance-backend.service"
SYSTEMD_UNIT_PATH="/etc/systemd/system/${SYSTEMD_UNIT_NAME}"
BACKUP_DIR="/var/backup/syslog-appliance-mvp1"
SELINUX_PORT=8080

DRY_RUN=false
PURGE=false

# ── 引数解析 ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
使用方法: $(basename "$0") [オプション]

オプション:
  --dry-run   実際の変更を行わず、実行内容を表示する
  --purge     DB ファイルと専用ユーザーも削除する（データ消失注意）
  --help      このヘルプを表示する
EOF
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --purge)   PURGE=true ;;
        --help)    usage ;;
        *) error "不明なオプション: $arg"; usage ;;
    esac
done

# ── dry-run ラッパー ─────────────────────────────────────────────────────────────
run() {
    if "$DRY_RUN"; then
        echo -e "${YELLOW}[DRY-RUN]${NC} $*"
    else
        "$@"
    fi
}

# ── root チェック ────────────────────────────────────────────────────────────────
if [[ "$EUID" -ne 0 ]]; then
    error "このスクリプトは root 権限で実行してください。"
    error "  sudo bash $(basename "$0")"
    exit 1
fi

if "$DRY_RUN"; then
    warn "DRY-RUN モード: 実際の変更は行いません"
fi
if "$PURGE"; then
    warn "PURGE モード: DB ファイルとユーザーも削除します"
fi

# ── 1. サービス停止・無効化 ──────────────────────────────────────────────────────
section "サービス停止・無効化"

if systemctl is-active --quiet "$SYSTEMD_UNIT_NAME" 2>/dev/null; then
    info "${SYSTEMD_UNIT_NAME} を停止します..."
    run systemctl stop "$SYSTEMD_UNIT_NAME"
    ok "停止しました"
else
    ok "${SYSTEMD_UNIT_NAME} は既に停止しています"
fi

if systemctl is-enabled --quiet "$SYSTEMD_UNIT_NAME" 2>/dev/null; then
    info "${SYSTEMD_UNIT_NAME} の自動起動を無効化します..."
    run systemctl disable "$SYSTEMD_UNIT_NAME"
    ok "自動起動を無効化しました"
else
    ok "${SYSTEMD_UNIT_NAME} の自動起動は既に無効です"
fi

# ── 2. systemd unit ファイル削除 ─────────────────────────────────────────────────
section "systemd unit ファイル削除"

if [[ -f "$SYSTEMD_UNIT_PATH" ]]; then
    run mkdir -p "$BACKUP_DIR"
    BACKUP="${BACKUP_DIR}/${SYSTEMD_UNIT_NAME}.bak.$(date +%Y%m%d_%H%M%S)"
    info "unit ファイルをバックアップ: ${BACKUP}"
    run mv "$SYSTEMD_UNIT_PATH" "$BACKUP"
    ok "unit ファイルをバックアップに移動しました"
else
    ok "unit ファイルは既に存在しません: ${SYSTEMD_UNIT_PATH}"
fi

run systemctl daemon-reload
ok "systemd をリロードしました"

# ── 3. firewalld からポート削除 ──────────────────────────────────────────────────
section "firewalld 設定削除"

if command -v firewall-cmd &>/dev/null; then
    if firewall-cmd --query-port="${SELINUX_PORT}/tcp" --permanent &>/dev/null; then
        info "firewalld からポート ${SELINUX_PORT}/tcp を削除します..."
        run firewall-cmd --permanent --remove-port="${SELINUX_PORT}/tcp"
        run firewall-cmd --reload
        ok "ポート ${SELINUX_PORT}/tcp を削除しました"
    else
        ok "ポート ${SELINUX_PORT}/tcp は既に削除されています"
    fi
else
    info "firewall-cmd が見つかりません。スキップします。"
fi

# ── 4. アプリケーションディレクトリ削除 ─────────────────────────────────────────
section "アプリケーションディレクトリ削除"

if [[ -d "$BACKEND_DIR" ]]; then
    info "${BACKEND_DIR} を削除します（venv を含む）..."
    run rm -rf "$BACKEND_DIR"
    ok "削除しました: ${BACKEND_DIR}"
else
    ok "既に存在しません: ${BACKEND_DIR}"
fi

# /opt/syslog-appliance が空になったら削除する
if [[ -d "$APP_HOME" ]] && [[ -z "$(ls -A "$APP_HOME" 2>/dev/null)" ]]; then
    info "${APP_HOME} が空のため削除します..."
    run rmdir "$APP_HOME"
    ok "削除しました: ${APP_HOME}"
fi

# ── 5. 環境変数ファイル削除 ──────────────────────────────────────────────────────
section "環境変数ファイル削除"

if [[ -f "$BACKEND_ENV" ]]; then
    run mkdir -p "$BACKUP_DIR"
    BACKUP="${BACKUP_DIR}/backend.env.bak.$(date +%Y%m%d_%H%M%S)"
    info "backend.env をバックアップ: ${BACKUP}"
    run mv "$BACKEND_ENV" "$BACKUP"
    ok "backend.env をバックアップに移動しました"
else
    ok "既に存在しません: ${BACKEND_ENV}"
fi

# ── 6. DB・ユーザー削除（--purge 時のみ） ───────────────────────────────────────
if "$PURGE"; then
    section "DB・ユーザー削除（PURGE モード）"

    DB_FILE="${DATA_DIR}/db.sqlite"
    if [[ -f "$DB_FILE" ]]; then
        warn "DB ファイルを削除します: ${DB_FILE}"
        run rm -f "$DB_FILE"
        ok "DB ファイルを削除しました"
    else
        ok "DB ファイルは既に存在しません: ${DB_FILE}"
    fi

    # data ディレクトリが空になったら削除
    if [[ -d "$DATA_DIR" ]] && [[ -z "$(ls -A "$DATA_DIR" 2>/dev/null)" ]]; then
        run rmdir "$DATA_DIR"
        ok "削除しました: ${DATA_DIR}"
    fi

    if id "$APP_USER" &>/dev/null; then
        info "ユーザー '${APP_USER}' を削除します..."
        run userdel "$APP_USER"
        ok "ユーザー '${APP_USER}' を削除しました"
    else
        ok "ユーザー '${APP_USER}' は既に存在しません"
    fi
else
    info "DB ファイルとユーザーは保持します（削除する場合は --purge を指定）"
fi

# ── 完了メッセージ ─────────────────────────────────────────────────────────────────
section "ロールバック完了"

echo ""
echo -e "${GREEN}${BOLD}✅ MVP 1.0 バックエンドのロールバックが完了しました${NC}"
echo ""
if ! "$PURGE"; then
    echo -e "${BOLD}保持されているもの:${NC}"
    echo "  - DB ファイル: ${DATA_DIR}/db.sqlite"
    echo "  - 専用ユーザー: ${APP_USER}"
    echo "  - バックアップ: ${BACKUP_DIR}/"
    echo ""
    echo "  完全削除する場合は --purge を指定して再実行してください"
fi
echo ""
