#!/usr/bin/env bash
# setup-mvp1-backend.sh
# MVP 1.0 バックエンド（FastAPI + uvicorn）のセットアップスクリプト
#
# 使用方法:
#   sudo bash setup-mvp1-backend.sh
#   sudo bash setup-mvp1-backend.sh --dry-run
#   sudo bash setup-mvp1-backend.sh --help
#
# ⚠️  このスクリプトは root 権限が必要です
# ⚠️  何度実行しても安全（冪等）です

set -euo pipefail

# ── カラー定義 ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'  # No Color

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${BOLD}── $* ──${NC}"; }

# ── 設定値 ──────────────────────────────────────────────────────────────────────
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_USER="syslog-appliance"
APP_HOME="/opt/syslog-appliance"
BACKEND_DIR="${APP_HOME}/backend"
VENV_DIR="${BACKEND_DIR}/venv"
DATA_DIR="/var/lib/syslog-appliance"
CONF_DIR="/etc/syslog-appliance"
BACKEND_ENV="${CONF_DIR}/backend.env"
SYSTEMD_UNIT_NAME="syslog-appliance-backend.service"
SYSTEMD_UNIT_DST="/etc/systemd/system/${SYSTEMD_UNIT_NAME}"
SELINUX_PORT=8080

DRY_RUN=false

# ── 引数解析 ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
使用方法: $(basename "$0") [オプション]

オプション:
  --dry-run   実際の変更を行わず、実行内容を表示する
  --help      このヘルプを表示する
EOF
    exit 0
}

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
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

# ── 1. 前提チェック ──────────────────────────────────────────────────────────────
section "前提チェック"

# Python 3.9 以降
PYTHON_BIN=$(command -v python3 || true)
if [[ -z "$PYTHON_BIN" ]]; then
    error "python3 が見つかりません。インストールしてください。"
    exit 1
fi
PYTHON_VER=$("$PYTHON_BIN" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
PYTHON_MAJOR=$(echo "$PYTHON_VER" | cut -d. -f1)
PYTHON_MINOR=$(echo "$PYTHON_VER" | cut -d. -f2)
if [[ "$PYTHON_MAJOR" -lt 3 || ( "$PYTHON_MAJOR" -eq 3 && "$PYTHON_MINOR" -lt 9 ) ]]; then
    error "Python 3.9 以降が必要です（現在: ${PYTHON_VER}）"
    exit 1
fi
ok "Python ${PYTHON_VER} を確認"

# pip
if ! "$PYTHON_BIN" -m pip --version &>/dev/null; then
    error "pip が見つかりません。python3-pip をインストールしてください。"
    exit 1
fi
ok "pip を確認"

# venv モジュール
if ! "$PYTHON_BIN" -m venv --help &>/dev/null; then
    error "venv モジュールが見つかりません。python3-venv をインストールしてください。"
    exit 1
fi
ok "venv を確認"

# systemd
if ! command -v systemctl &>/dev/null; then
    error "systemctl が見つかりません。systemd 環境が必要です。"
    exit 1
fi
ok "systemd を確認"

# firewalld
if ! command -v firewall-cmd &>/dev/null; then
    warn "firewall-cmd が見つかりません。firewalld の設定はスキップします。"
    FIREWALLD_AVAILABLE=false
else
    FIREWALLD_AVAILABLE=true
    ok "firewalld を確認"
fi

# semanage (SELinux 管理コマンド)
if ! command -v semanage &>/dev/null; then
    warn "semanage が見つかりません。policycoreutils-python-utils をインストールしてください。SELinux 設定はスキップします。"
    SELINUX_AVAILABLE=false
else
    SELINUX_AVAILABLE=true
    ok "semanage を確認"
fi

# requirements.txt の存在確認
REQUIREMENTS="${REPO_DIR}/backend/requirements.txt"
if [[ ! -f "$REQUIREMENTS" ]]; then
    error "requirements.txt が見つかりません: ${REQUIREMENTS}"
    exit 1
fi
ok "requirements.txt を確認: ${REQUIREMENTS}"

# ── 2. 専用ユーザー作成 ──────────────────────────────────────────────────────────
section "専用ユーザー作成"

if id "$APP_USER" &>/dev/null; then
    ok "ユーザー '${APP_USER}' は既に存在します。スキップ。"
else
    info "ユーザー '${APP_USER}' を作成します..."
    run useradd \
        --system \
        --shell /sbin/nologin \
        --home-dir "$APP_HOME" \
        --no-create-home \
        "$APP_USER"
    ok "ユーザー '${APP_USER}' を作成しました"
fi

# ── 3. ディレクトリ作成 ──────────────────────────────────────────────────────────
section "ディレクトリ作成"

for dir in "$APP_HOME" "$BACKEND_DIR" "$DATA_DIR" "$CONF_DIR"; do
    if [[ -d "$dir" ]]; then
        ok "既に存在: ${dir}"
    else
        info "作成: ${dir}"
        run mkdir -p "$dir"
    fi
done

# パーミッション設定
run chown "${APP_USER}:${APP_USER}" "$BACKEND_DIR"
run chmod 0755 "$BACKEND_DIR"
run chown "${APP_USER}:${APP_USER}" "$DATA_DIR"
run chmod 0750 "$DATA_DIR"
ok "ディレクトリのパーミッションを設定しました"

# ── 4. Python venv 作成 ──────────────────────────────────────────────────────────
section "Python venv 作成"

if [[ -d "$VENV_DIR" ]]; then
    ok "venv は既に存在します: ${VENV_DIR}"
else
    info "venv を作成します: ${VENV_DIR}"
    run "$PYTHON_BIN" -m venv "$VENV_DIR"
    run chown -R "${APP_USER}:${APP_USER}" "$VENV_DIR"
    ok "venv を作成しました"
fi

# ── 5. pip install ────────────────────────────────────────────────────────────────
section "パッケージインストール"

info "requirements.txt からインストールします..."
run "${VENV_DIR}/bin/pip" install --quiet --upgrade pip
run "${VENV_DIR}/bin/pip" install --quiet -r "$REQUIREMENTS"
ok "パッケージのインストールが完了しました"

# ── 6. アプリケーションコピー ────────────────────────────────────────────────────
section "アプリケーションコピー"

info "backend/app/ をコピーします..."
run cp -r "${REPO_DIR}/backend/app" "${BACKEND_DIR}/"
run cp "${REPO_DIR}/backend/requirements.txt" "${BACKEND_DIR}/"
run chown -R "${APP_USER}:${APP_USER}" "${BACKEND_DIR}/app"
ok "アプリケーションをコピーしました: ${BACKEND_DIR}/app"

# ── 7. systemd unit 配置 ──────────────────────────────────────────────────────────
section "systemd unit 配置"

UNIT_SRC="${REPO_DIR}/systemd/${SYSTEMD_UNIT_NAME}"
if [[ ! -f "$UNIT_SRC" ]]; then
    error "systemd unit ファイルが見つかりません: ${UNIT_SRC}"
    exit 1
fi

if [[ -f "$SYSTEMD_UNIT_DST" ]]; then
    BACKUP="${SYSTEMD_UNIT_DST}.bak.$(date +%Y%m%d_%H%M%S)"
    info "既存の unit をバックアップ: ${BACKUP}"
    run cp "$SYSTEMD_UNIT_DST" "$BACKUP"
fi

run cp "$UNIT_SRC" "$SYSTEMD_UNIT_DST"
run chmod 644 "$SYSTEMD_UNIT_DST"
ok "systemd unit を配置しました: ${SYSTEMD_UNIT_DST}"

# ── 8. 環境変数ファイル配置 ──────────────────────────────────────────────────────
section "環境変数ファイル配置"

ENV_SRC="${REPO_DIR}/systemd/syslog-appliance-backend.env"
if [[ ! -f "$ENV_SRC" ]]; then
    error "環境変数雛形ファイルが見つかりません: ${ENV_SRC}"
    exit 1
fi

if [[ -f "$BACKEND_ENV" ]]; then
    BACKUP="${BACKEND_ENV}.bak.$(date +%Y%m%d_%H%M%S)"
    info "既存の backend.env をバックアップ: ${BACKUP}"
    run cp "$BACKEND_ENV" "$BACKUP"
    ok "既存の設定をバックアップしました（上書きします）"
fi

run cp "$ENV_SRC" "$BACKEND_ENV"
# AUTH_PASS を含むため root のみ読み書き可、syslog-appliance は読み取りのみ
run chown "root:${APP_USER}" "$BACKEND_ENV"
run chmod 640 "$BACKEND_ENV"
ok "環境変数ファイルを配置しました: ${BACKEND_ENV}"

# パスワード未設定チェック
AUTH_PASS_VALUE=$(grep -E '^SYSLOG_APPLIANCE_AUTH_PASS=' "$BACKEND_ENV" | cut -d= -f2 || true)
if [[ -z "$AUTH_PASS_VALUE" ]]; then
    warn "⚠️  SYSLOG_APPLIANCE_AUTH_PASS が未設定です！"
    warn "   ${BACKEND_ENV} を編集してパスワードを設定してから"
    warn "   systemctl start ${SYSTEMD_UNIT_NAME} を実行してください。"
fi

# ── 9. SELinux 設定 ───────────────────────────────────────────────────────────────
section "SELinux 設定"

if "$SELINUX_AVAILABLE"; then
    # ポート 8080 が http_port_t に含まれているか確認
    if semanage port -l | grep -q "^http_port_t.*tcp.*8080"; then
        ok "ポート ${SELINUX_PORT}/tcp は既に http_port_t に含まれています。"
    else
        info "ポート ${SELINUX_PORT}/tcp を http_port_t に追加します..."
        run semanage port -a -t http_port_t -p tcp "$SELINUX_PORT"
        ok "SELinux: ポート ${SELINUX_PORT}/tcp を http_port_t に追加しました"
    fi
else
    info "SELinux 設定をスキップしました"
fi

# ── 10. firewalld 設定 ────────────────────────────────────────────────────────────
section "firewalld 設定"

if "$FIREWALLD_AVAILABLE"; then
    if firewall-cmd --query-port="${SELINUX_PORT}/tcp" --permanent &>/dev/null; then
        ok "ポート ${SELINUX_PORT}/tcp は既に許可されています。"
    else
        info "firewalld にポート ${SELINUX_PORT}/tcp を追加します..."
        run firewall-cmd --permanent --add-port="${SELINUX_PORT}/tcp"
        run firewall-cmd --reload
        ok "firewalld: ポート ${SELINUX_PORT}/tcp を許可しました"
    fi
else
    info "firewalld 設定をスキップしました"
fi

# ── 11. systemd 有効化（起動はしない） ───────────────────────────────────────────
section "systemd 有効化"

run systemctl daemon-reload
run systemctl enable "$SYSTEMD_UNIT_NAME"
ok "systemd に登録しました（自動起動を有効化）"

# ── 完了メッセージ ─────────────────────────────────────────────────────────────────
section "セットアップ完了"

echo ""
echo -e "${GREEN}${BOLD}✅ MVP 1.0 バックエンドのセットアップが完了しました${NC}"
echo ""
echo -e "${BOLD}次にやること:${NC}"
echo "  1. パスワードを設定する:"
echo -e "     ${CYAN}sudo vi ${BACKEND_ENV}${NC}"
echo "     SYSLOG_APPLIANCE_AUTH_PASS= に強力なパスワードを設定してください"
echo ""
echo "  2. サービスを起動する:"
echo -e "     ${CYAN}sudo systemctl start ${SYSTEMD_UNIT_NAME}${NC}"
echo ""
echo "  3. 起動確認:"
echo -e "     ${CYAN}systemctl status ${SYSTEMD_UNIT_NAME}${NC}"
echo -e "     ${CYAN}curl http://localhost:8080/healthz${NC}"
echo ""
echo -e "  4. API ドキュメント（起動後にブラウザで確認）:"
echo -e "     ${CYAN}http://$(hostname -I | awk '{print $1}'):8080/docs${NC}"
echo ""
