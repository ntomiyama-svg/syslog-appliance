#!/usr/bin/env bash
# generate-self-signed-cert.sh
# 自己署名 TLS 証明書を生成し /etc/syslog-appliance/ssl/ に配置する。
# SAN(Subject Alternative Names)に IP と DNS 両方を含める。
#
# 使い方:
#   sudo bash scripts/generate-self-signed-cert.sh [オプション]
#
# オプション:
#   --cn <CN>     Common Name (デフォルト: syslog-appliance-dev)
#   --ip <IP>     SAN に含める IP アドレス (デフォルト: 10.18.115.29)
#   --days <N>    有効期限（日数）(デフォルト: 825)
#   --force       既存の証明書を上書きする
#   --help        このヘルプを表示する

set -euo pipefail

# ===== カラー出力ヘルパー =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()   { error "$*"; exit 1; }

# ===== デフォルト値 =====
CN="syslog-appliance-dev"
IP="10.18.115.29"
DAYS=825
FORCE=false
SSL_DIR="/etc/syslog-appliance/ssl"
CERT="${SSL_DIR}/server.crt"
KEY="${SSL_DIR}/server.key"

# ===== 引数パース =====
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cn)    shift; CN="$1" ;;
        --ip)    shift; IP="$1" ;;
        --days)  shift; DAYS="$1" ;;
        --force) FORCE=true ;;
        --help)
            sed -n '2,20p' "$0" | sed 's/^# *//'
            exit 0
            ;;
        *) die "不明なオプション: $1 (--help で使い方を確認してください)" ;;
    esac
    shift
done

# ===== root チェック =====
if [[ $EUID -ne 0 ]]; then
    die "このスクリプトは root で実行してください: sudo $0 $*"
fi

# ===== openssl チェック =====
if ! command -v openssl &>/dev/null; then
    die "openssl がインストールされていません。dnf install -y openssl を実行してください。"
fi

info "=== 自己署名 TLS 証明書の生成 ==="
info "  CN   : ${CN}"
info "  SAN  : IP:${IP}, DNS:${CN}"
info "  有効期限: ${DAYS} 日"
info "  出力先  : ${CERT}"

# ===== 既存証明書のチェック =====
if [[ -f "${CERT}" ]] && [[ "${FORCE}" == false ]]; then
    warn "証明書が既に存在します: ${CERT}"
    warn "--force オプションを指定すると上書きします。"
    exit 0
fi

# ===== ディレクトリ作成 =====
info "出力ディレクトリを確認・作成します: ${SSL_DIR}"
mkdir -p "${SSL_DIR}"
chmod 700 "${SSL_DIR}"
chown root:root "${SSL_DIR}"
ok "ディレクトリ準備完了"

# ===== SAN 設定ファイルを一時作成 =====
TMP_CONF="$(mktemp /tmp/openssl-san-XXXXXX.cnf)"
trap 'rm -f "${TMP_CONF}"' EXIT

cat > "${TMP_CONF}" <<EOF
[req]
default_bits       = 2048
default_md         = sha256
distinguished_name = req_distinguished_name
x509_extensions    = v3_req
prompt             = no

[req_distinguished_name]
CN = ${CN}

[v3_req]
subjectAltName = @alt_names
keyUsage       = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth

[alt_names]
DNS.1 = ${CN}
IP.1  = ${IP}
EOF

# ===== 証明書生成 =====
info "秘密鍵と証明書を生成しています..."
openssl req \
    -x509 \
    -newkey rsa:2048 \
    -sha256 \
    -days "${DAYS}" \
    -nodes \
    -keyout "${KEY}" \
    -out    "${CERT}" \
    -config "${TMP_CONF}" \
    2>/dev/null

# ===== パーミッション設定 =====
chmod 600 "${KEY}"
chmod 644 "${CERT}"
chown root:root "${KEY}" "${CERT}"

ok "証明書を生成しました"

# ===== 証明書情報の表示 =====
echo ""
info "=== 生成された証明書の情報 ==="
openssl x509 -in "${CERT}" -noout \
    -subject \
    -issuer \
    -dates \
    -ext subjectAltName 2>/dev/null || true

echo ""
ok "=== 完了 ==="
info "証明書: ${CERT}"
info "秘密鍵: ${KEY}"
echo ""
info "次のステップ:"
info "  nginx の再起動: sudo systemctl restart nginx"
info "  ブラウザで接続: https://${IP}/"
info "  (自己署名証明書のため、ブラウザの警告は「詳細設定」→「接続を続ける」で許可してください)"
