#!/usr/bin/env bash
# setup-mvp1-frontend.sh
# MVP 1.1 フロントエンド（nginx + HTTPS）のセットアップスクリプト。
#
# 処理順序:
#   1. 前提チェック（nginx / openssl のインストール確認・導入）
#   2. SELinux: httpd_can_network_connect を on に設定
#   3. フロントエンド静的ファイルの配置
#   4. nginx 設定の配置
#   5. 自己署名証明書の生成（--skip-cert で省略可）
#   6. systemd drop-in の配置
#   7. nginx 設定の構文チェック
#   8. firewalld のルール変更（8080/tcp を閉じ、80/tcp, 443/tcp を許可）
#   9. バックエンドの再起動（127.0.0.1 に切り替え）
#  10. nginx の有効化・起動
#  11. 動作確認情報の表示
#
# 使い方:
#   sudo bash scripts/setup-mvp1-frontend.sh [オプション]
#
# オプション:
#   --dry-run    実際の変更を行わず、実行内容だけを表示する
#   --skip-cert  証明書生成をスキップする（既存証明書がある場合）
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

# dry-run 用のラッパー: dry-run 時は echo するだけ
run() {
    if [[ "${DRY_RUN}" == true ]]; then
        echo -e "  ${YELLOW}[DRY-RUN]${NC} $*"
    else
        eval "$*"
    fi
}

# ===== デフォルト値 =====
DRY_RUN=false
SKIP_CERT=false

# リポジトリルートを特定する（スクリプト位置から相対パスで求める）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# 配置先パス
FRONTEND_SRC="${REPO_ROOT}/frontend/dist"
FRONTEND_DST="/opt/syslog-appliance/frontend/dist"
NGINX_CONF_SRC="${REPO_ROOT}/nginx/syslog-appliance.conf"
NGINX_CONF_DST="/etc/nginx/conf.d/syslog-appliance.conf"
DROPIN_SRC="${REPO_ROOT}/systemd/syslog-appliance-backend.service.d/listen-localhost.conf"
DROPIN_DST="/etc/systemd/system/syslog-appliance-backend.service.d/listen-localhost.conf"
BACKEND_ENV="/etc/syslog-appliance/backend.env"
SSL_DIR="/etc/syslog-appliance/ssl"
CERT_SCRIPT="${SCRIPT_DIR}/generate-self-signed-cert.sh"
APPLIANCE_IP="10.18.115.29"

# ===== 引数パース =====
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)   DRY_RUN=true ;;
        --skip-cert) SKIP_CERT=true ;;
        --help)
            sed -n '2,30p' "$0" | sed 's/^# *//'
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
echo "=========================================="
echo " syslog-appliance MVP 1.1 セットアップ"
echo "=========================================="
echo -e "${NC}"

if [[ "${DRY_RUN}" == true ]]; then
    warn "*** DRY-RUN モード: 実際の変更は行いません ***"
    echo ""
fi

# ===========================================================================
# Step 1: 前提チェック
# ===========================================================================
step "Step 1: 前提チェック"

# openssl チェック
if ! command -v openssl &>/dev/null; then
    info "openssl が見つかりません。インストールします..."
    run "dnf install -y openssl"
fi
ok "openssl: $(openssl version 2>/dev/null | head -1 || echo 'OK')"

# nginx チェック
if ! command -v nginx &>/dev/null; then
    info "nginx が見つかりません。インストールします..."
    run "dnf install -y nginx"
fi
ok "nginx: $(nginx -v 2>&1 | head -1 || echo 'OK')"

# MVP 1.0 セットアップ済みか確認（syslog-appliance ユーザーと /opt ディレクトリ）
if ! id syslog-appliance &>/dev/null; then
    die "syslog-appliance ユーザーが存在しません。先に setup-mvp1-backend.sh を実行してください。"
fi
ok "syslog-appliance ユーザー: OK"

if [[ ! -d "/opt/syslog-appliance/backend" ]]; then
    die "/opt/syslog-appliance/backend が存在しません。先に setup-mvp1-backend.sh を実行してください。"
fi
ok "/opt/syslog-appliance/backend: OK"

# リポジトリのソースファイル確認
if [[ ! -f "${NGINX_CONF_SRC}" ]]; then
    die "nginx 設定ファイルが見つかりません: ${NGINX_CONF_SRC}"
fi
if [[ ! -d "${FRONTEND_SRC}" ]]; then
    die "フロントエンド dist が見つかりません: ${FRONTEND_SRC}"
fi
if [[ ! -f "${DROPIN_SRC}" ]]; then
    die "systemd drop-in が見つかりません: ${DROPIN_SRC}"
fi
ok "ソースファイル: OK"

# ===========================================================================
# Step 2: SELinux 設定
# ===========================================================================
step "Step 2: SELinux - httpd_can_network_connect を有効化"

if command -v setsebool &>/dev/null; then
    info "httpd_can_network_connect=on を永続設定します..."
    run "setsebool -P httpd_can_network_connect 1"
    ok "httpd_can_network_connect: on (永続)"
else
    warn "setsebool が見つかりません。SELinux が無効な環境の可能性があります。スキップします。"
fi

# ===========================================================================
# Step 3: フロントエンド静的ファイルの配置
# ===========================================================================
step "Step 3: フロントエンド静的ファイルの配置"

info "配置先: ${FRONTEND_DST}"
run "mkdir -p '${FRONTEND_DST}'"
run "cp -r '${FRONTEND_SRC}/.' '${FRONTEND_DST}/'"

# 所有者とパーミッション設定
run "chown -R nginx:nginx '${FRONTEND_DST}'"
run "find '${FRONTEND_DST}' -type d -exec chmod 0755 {} +"
run "find '${FRONTEND_DST}' -type f -exec chmod 0644 {} +"

ok "フロントエンドファイルを配置しました: ${FRONTEND_DST}"

# ===========================================================================
# Step 4: nginx 設定の配置
# ===========================================================================
step "Step 4: nginx 設定の配置"

# 既存の default.conf をバックアップ（競合防止のための情報提供）
if [[ -f "/etc/nginx/conf.d/default.conf" ]]; then
    warn "/etc/nginx/conf.d/default.conf が存在します。"
    warn "ポート 80 で競合する場合は手動で無効化してください:"
    warn "  sudo mv /etc/nginx/conf.d/default.conf /etc/nginx/conf.d/default.conf.disabled"
fi

run "cp '${NGINX_CONF_SRC}' '${NGINX_CONF_DST}'"
run "chmod 644 '${NGINX_CONF_DST}'"
ok "nginx 設定を配置しました: ${NGINX_CONF_DST}"

# ===========================================================================
# Step 5: 自己署名証明書の生成
# ===========================================================================
step "Step 5: 自己署名証明書の生成"

if [[ "${SKIP_CERT}" == true ]]; then
    warn "--skip-cert が指定されました。証明書生成をスキップします。"
    if [[ ! -f "${SSL_DIR}/server.crt" ]] || [[ ! -f "${SSL_DIR}/server.key" ]]; then
        die "証明書ファイルが存在しません: ${SSL_DIR}/server.crt, ${SSL_DIR}/server.key"
    fi
    ok "既存の証明書を使用します: ${SSL_DIR}/server.crt"
elif [[ -f "${SSL_DIR}/server.crt" ]] && [[ -f "${SSL_DIR}/server.key" ]]; then
    info "証明書が既に存在します。スキップします。"
    info "(上書きするには --skip-cert を外して generate-self-signed-cert.sh --force を実行)"
    ok "既存の証明書を使用します: ${SSL_DIR}/server.crt"
else
    info "自己署名証明書を生成します..."
    if [[ "${DRY_RUN}" == true ]]; then
        info "[DRY-RUN] bash '${CERT_SCRIPT}' --ip '${APPLIANCE_IP}' を実行します"
    else
        bash "${CERT_SCRIPT}" --ip "${APPLIANCE_IP}"
    fi
    ok "証明書を生成しました"
fi

# ===========================================================================
# Step 6: systemd drop-in の配置
# ===========================================================================
step "Step 6: systemd drop-in の配置（バックエンドを 127.0.0.1 に絞る）"

DROPIN_DST_DIR="$(dirname "${DROPIN_DST}")"
run "mkdir -p '${DROPIN_DST_DIR}'"
run "cp '${DROPIN_SRC}' '${DROPIN_DST}'"
run "chmod 644 '${DROPIN_DST}'"
ok "drop-in を配置しました: ${DROPIN_DST}"

run "systemctl daemon-reload"
ok "systemd デーモンをリロードしました"

# ===========================================================================
# Step 7: nginx 設定の構文チェック
# ===========================================================================
step "Step 7: nginx 設定の構文チェック"

if [[ "${DRY_RUN}" == true ]]; then
    warn "[DRY-RUN] nginx -t をスキップします"
else
    if ! nginx -t 2>&1; then
        die "nginx 設定に構文エラーがあります。上記のエラーを確認してください。"
    fi
    ok "nginx 設定の構文チェック: OK"
fi

# ===========================================================================
# Step 8: firewalld の変更
# ===========================================================================
step "Step 8: firewalld のポート変更（8080 を閉じ、80/443 を許可）"

if command -v firewall-cmd &>/dev/null; then
    # 8080/tcp を削除（エラーは無視: 既に削除済みの場合）
    run "firewall-cmd --permanent --remove-port=8080/tcp 2>/dev/null || true"
    info "8080/tcp を削除しました（または既に存在しませんでした）"

    # 80/tcp (http) を許可
    run "firewall-cmd --permanent --add-service=http"
    ok "http (80/tcp) を許可しました"

    # 443/tcp (https) を許可
    run "firewall-cmd --permanent --add-service=https"
    ok "https (443/tcp) を許可しました"

    # firewalld をリロード
    run "firewall-cmd --reload"
    ok "firewalld をリロードしました"
else
    warn "firewall-cmd が見つかりません。firewalld が無効な環境の可能性があります。スキップします。"
fi

# ===========================================================================
# Step 9: バックエンドの再起動（127.0.0.1 への切り替え）
# ===========================================================================
step "Step 9: バックエンドの再起動（listen: 0.0.0.0 → 127.0.0.1）"

run "systemctl restart syslog-appliance-backend.service"
ok "syslog-appliance-backend を再起動しました"

# 少し待って起動確認
if [[ "${DRY_RUN}" != true ]]; then
    sleep 2
    if ! systemctl is-active --quiet syslog-appliance-backend.service; then
        warn "バックエンドが起動していません。ログを確認してください:"
        warn "  sudo journalctl -u syslog-appliance-backend.service -n 30"
    else
        ok "バックエンド: active (running)"
    fi
fi

# ===========================================================================
# Step 10: nginx の有効化・起動
# ===========================================================================
step "Step 10: nginx の有効化・起動"

run "systemctl enable --now nginx.service"
ok "nginx を有効化・起動しました"

# 少し待って起動確認
if [[ "${DRY_RUN}" != true ]]; then
    sleep 1
    if ! systemctl is-active --quiet nginx.service; then
        warn "nginx が起動していません。ログを確認してください:"
        warn "  sudo journalctl -u nginx.service -n 30"
        warn "  sudo nginx -t"
    else
        ok "nginx: active (running)"
    fi
fi

# ===========================================================================
# Step 11: 動作確認情報の表示
# ===========================================================================
step "Step 11: 動作確認"

if [[ "${DRY_RUN}" != true ]]; then
    echo ""
    info "--- listen ポート ---"
    ss -tlnp 2>/dev/null | grep -E ':(80|443|8080)\b' || true

    echo ""
    info "--- ヘルスチェック (curl -k https://localhost/healthz) ---"
    if command -v curl &>/dev/null; then
        curl -sk --max-time 5 "https://localhost/healthz" | python3 -m json.tool 2>/dev/null || \
            warn "ヘルスチェックに失敗しました（バックエンドが起動中の場合は少し待ってから再試行してください）"
    fi
fi

echo ""
echo -e "${GREEN}${BOLD}=========================================="
echo " MVP 1.1 セットアップが完了しました！"
echo "==========================================${NC}"
echo ""
info "次のステップ:"
info "  1. ブラウザで https://${APPLIANCE_IP}/ を開く"
info "  2. 自己署名証明書の警告が出たら「詳細設定」→「接続を続ける」を選択"
info "  3. Basic 認証ダイアログが出たらユーザー名/パスワードを入力"
info "     (backend.env の AUTH_USER / AUTH_PASS に設定した値)"
echo ""
info "確認コマンド:"
info "  sudo systemctl status nginx.service"
info "  sudo systemctl status syslog-appliance-backend.service"
info "  curl -k https://${APPLIANCE_IP}/healthz"
info "  curl -k https://${APPLIANCE_IP}/api/v1/devices"
echo ""
