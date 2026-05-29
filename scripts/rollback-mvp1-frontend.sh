#!/usr/bin/env bash
# rollback-mvp1-frontend.sh
# MVP 1.1 フロントエンド（nginx + HTTPS）のロールバックスクリプト。
# MVP 1.0 の状態（バックエンドが 0.0.0.0:8080 で listen）に戻す。
#
# 処理内容:
#   1. nginx の停止・無効化
#   2. nginx 設定ファイルをバックアップに移動
#   3. systemd drop-in をバックアップに移動
#   4. バックエンドを再起動（0.0.0.0:8080 に戻す）
#   5. firewalld のルール変更（80/443 を削除、8080/tcp を許可）
#   6. フロントエンド静的ファイルの削除
#   7. 証明書の削除（--purge-cert 指定時のみ）
#
# 使い方:
#   sudo bash scripts/rollback-mvp1-frontend.sh [オプション]
#
# オプション:
#   --dry-run    実際の変更を行わず、実行内容だけを表示する
#   --purge-cert 証明書も削除する（通常は削除しない）
#   --help       このヘルプを表示する

set -euo pipefail

# ===== カラー出力ヘルパー =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { error "$*"; exit 1; }
step()  { echo -e "\n${BOLD}>>> $*${NC}"; }

run() {
    if [[ "${DRY_RUN}" == true ]]; then
        echo -e "  ${YELLOW}[DRY-RUN]${NC} $*"
    else
        eval "$*"
    fi
}

# ===== デフォルト値 =====
DRY_RUN=false
PURGE_CERT=false

# タイムスタンプ（バックアップファイル名に使用）
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"

# 各パス
NGINX_CONF="/etc/nginx/conf.d/syslog-appliance.conf"
DROPIN="/etc/systemd/system/syslog-appliance-backend.service.d/listen-localhost.conf"
FRONTEND_DST="/opt/syslog-appliance/frontend/dist"
SSL_DIR="/etc/syslog-appliance/ssl"

# ===== 引数パース =====
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)    DRY_RUN=true ;;
        --purge-cert) PURGE_CERT=true ;;
        --help)
            sed -n '2,35p' "$0" | sed 's/^# *//'
            exit 0
            ;;
        *) die "不明なオプション: $1 (--help で使い方を確認してください)" ;;
    esac
    shift
done

# ===== root チェック =====
if [[ $EUID -ne 0 ]]; then
    die "このスクリプトは root で実行してください: sudo $0"
fi

echo -e "${BOLD}"
echo "=============================================="
echo " syslog-appliance MVP 1.1 ロールバック"
echo "=============================================="
echo -e "${NC}"

if [[ "${DRY_RUN}" == true ]]; then
    warn "*** DRY-RUN モード: 実際の変更は行いません ***"
    echo ""
fi

# ===========================================================================
# Step 1: nginx の停止・無効化
# ===========================================================================
step "Step 1: nginx の停止・無効化"

if systemctl is-active --quiet nginx.service 2>/dev/null; then
    run "systemctl stop nginx.service"
    ok "nginx を停止しました"
else
    info "nginx はすでに停止しています"
fi

if systemctl is-enabled --quiet nginx.service 2>/dev/null; then
    run "systemctl disable nginx.service"
    ok "nginx の自動起動を無効化しました"
else
    info "nginx の自動起動はすでに無効です"
fi

# ===========================================================================
# Step 2: nginx 設定ファイルをバックアップに移動
# ===========================================================================
step "Step 2: nginx 設定ファイルのバックアップ"

if [[ -f "${NGINX_CONF}" ]]; then
    BACKUP="${NGINX_CONF}.rollback-${TIMESTAMP}"
    run "mv '${NGINX_CONF}' '${BACKUP}'"
    ok "nginx 設定をバックアップしました: ${BACKUP}"
else
    info "nginx 設定が見つかりません。スキップします: ${NGINX_CONF}"
fi

# ===========================================================================
# Step 3: systemd drop-in をバックアップに移動
# ===========================================================================
step "Step 3: systemd drop-in のバックアップ"

if [[ -f "${DROPIN}" ]]; then
    DROPIN_BACKUP="${DROPIN}.rollback-${TIMESTAMP}"
    run "mv '${DROPIN}' '${DROPIN_BACKUP}'"
    ok "drop-in をバックアップしました: ${DROPIN_BACKUP}"
else
    info "drop-in が見つかりません。スキップします: ${DROPIN}"
fi

run "systemctl daemon-reload"
ok "systemd デーモンをリロードしました"

# ===========================================================================
# Step 4: バックエンドの再起動（0.0.0.0 に戻す）
# ===========================================================================
step "Step 4: バックエンドの再起動（listen: 127.0.0.1 → 0.0.0.0）"

if systemctl is-active --quiet syslog-appliance-backend.service 2>/dev/null || \
   systemctl is-failed --quiet syslog-appliance-backend.service 2>/dev/null; then
    run "systemctl restart syslog-appliance-backend.service"
    ok "syslog-appliance-backend を再起動しました"
else
    info "syslog-appliance-backend が起動していません。起動を試みます..."
    run "systemctl start syslog-appliance-backend.service || true"
fi

# ===========================================================================
# Step 5: firewalld のルール変更
# ===========================================================================
step "Step 5: firewalld のポート変更（80/443 を削除、8080/tcp を許可）"

if command -v firewall-cmd &>/dev/null; then
    # http/https を削除（エラーは無視）
    run "firewall-cmd --permanent --remove-service=http  2>/dev/null || true"
    info "http (80/tcp) を削除しました（または既に存在しませんでした）"

    run "firewall-cmd --permanent --remove-service=https 2>/dev/null || true"
    info "https (443/tcp) を削除しました（または既に存在しませんでした）"

    # 8080/tcp を許可（元の状態に戻す）
    run "firewall-cmd --permanent --add-port=8080/tcp"
    ok "8080/tcp を許可しました（元の状態に戻しました）"

    run "firewall-cmd --reload"
    ok "firewalld をリロードしました"
else
    warn "firewall-cmd が見つかりません。スキップします。"
fi

# ===========================================================================
# Step 6: フロントエンド静的ファイルの削除
# ===========================================================================
step "Step 6: フロントエンド静的ファイルの削除"

if [[ -d "${FRONTEND_DST}" ]]; then
    run "rm -rf '${FRONTEND_DST}'"
    ok "フロントエンドファイルを削除しました: ${FRONTEND_DST}"
else
    info "フロントエンドファイルが見つかりません。スキップします: ${FRONTEND_DST}"
fi

# ===========================================================================
# Step 7: 証明書の削除（--purge-cert 時のみ）
# ===========================================================================
step "Step 7: 証明書の削除"

if [[ "${PURGE_CERT}" == true ]]; then
    if [[ -d "${SSL_DIR}" ]]; then
        run "rm -rf '${SSL_DIR}'"
        ok "証明書を削除しました: ${SSL_DIR}"
    else
        info "証明書ディレクトリが見つかりません: ${SSL_DIR}"
    fi
else
    info "--purge-cert が指定されていないため、証明書は削除しません。"
    info "(削除するには: sudo bash rollback-mvp1-frontend.sh --purge-cert)"
fi

# ===========================================================================
# 完了
# ===========================================================================
echo ""
echo -e "${GREEN}${BOLD}================================================"
echo " MVP 1.1 ロールバックが完了しました"
echo "================================================${NC}"
echo ""
info "バックエンドは 0.0.0.0:8080 で再起動されました（drop-in が削除されたため）"
info "8080/tcp が firewalld で許可されています"
echo ""
info "確認コマンド:"
info "  sudo systemctl status syslog-appliance-backend.service"
info "  sudo firewall-cmd --list-all"
info "  ss -tlnp | grep ':8080'"
echo ""
warn "注意: SELinux の httpd_can_network_connect は変更しません。"
warn "  （他の用途で使われている可能性があるため）"
echo ""
