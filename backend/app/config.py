"""設定読み込みモジュール。環境変数から設定値を取得する。"""

import logging
import os

logger = logging.getLogger(__name__)

# バージョン情報
APP_VERSION = "1.0.0"
APP_NAME = "syslog-appliance-backend"


def get_db_path() -> str:
    return os.environ.get(
        "SYSLOG_APPLIANCE_DB_PATH",
        "/var/lib/syslog-appliance/db.sqlite",
    )


def get_config_path() -> str:
    return os.environ.get(
        "SYSLOG_APPLIANCE_CONFIG_PATH",
        "/etc/syslog-appliance/appliance.conf",
    )


def get_auth_user() -> str:
    return os.environ.get("SYSLOG_APPLIANCE_AUTH_USER", "admin")


def get_auth_pass() -> str:
    return os.environ.get("SYSLOG_APPLIANCE_AUTH_PASS", "")


def get_log_level() -> str:
    return os.environ.get("SYSLOG_APPLIANCE_LOG_LEVEL", "INFO").upper()


def validate_config() -> None:
    """起動時の設定検証。致命的な問題は例外、警告は warning ログ。"""
    if not get_auth_pass():
        logger.warning(
            "SYSLOG_APPLIANCE_AUTH_PASS が未設定です。"
            "本番運用前に必ず /etc/syslog-appliance/backend.env で設定してください。"
        )
