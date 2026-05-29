"""システム情報 API。/api/v1/system 配下のエンドポイントを定義する。"""

import logging
import os
from datetime import datetime, timezone
from typing import Any, Dict

from fastapi import APIRouter, Depends, HTTPException, status

from ..auth import require_auth
from .. import config

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/v1/system", tags=["system"])

# アプリ起動時刻（モジュール読み込みタイミングで固定）
_startup_time: datetime = datetime.now(timezone.utc)


@router.get("/info", response_model=Dict[str, Any])
def get_system_info(_user: str = Depends(require_auth)):
    """システム情報を返す。バージョン、起動時刻、設定パス等を含む。"""
    return {
        "app_name": config.APP_NAME,
        "version": config.APP_VERSION,
        "startup_time": _startup_time.isoformat(),
        "db_path": config.get_db_path(),
        "config_path": config.get_config_path(),
        "auth_user": config.get_auth_user(),
        # パスワードは返さない
        "auth_pass_configured": bool(config.get_auth_pass()),
    }


@router.get("/appliance-conf", response_model=Dict[str, Any])
def get_appliance_conf(_user: str = Depends(require_auth)):
    """appliance.conf の内容を返す。機密情報はマスクして返す。

    MVP 1.0 では appliance.conf に機密情報はないが、
    将来の拡張に備えてマスク処理の枠を用意している。
    """
    conf_path = config.get_config_path()

    if not os.path.exists(conf_path):
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"設定ファイルが見つかりません: {conf_path}",
        )

    try:
        with open(conf_path, "r", encoding="utf-8") as f:
            raw_lines = f.readlines()
    except PermissionError:
        logger.error("設定ファイルの読み取り権限がありません: %s", conf_path)
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="設定ファイルの読み取りに失敗しました（権限エラー）。",
        )

    # 将来の機密マスク処理のプレースホルダー
    # 現在 appliance.conf に機密情報は含まれないが、
    # password= や secret= などを含む行はここで "*****" に置換する。
    masked_lines = [_mask_sensitive_line(line) for line in raw_lines]

    return {
        "path": conf_path,
        "content": "".join(masked_lines),
        "line_count": len(raw_lines),
    }


# 将来追加される機密キーワードのリスト（今は空）
_SENSITIVE_KEYWORDS = ["password=", "secret=", "token=", "key="]


def _mask_sensitive_line(line: str) -> str:
    """機密情報を含む行の値部分を '*****' に置換する。"""
    stripped = line.strip().lower()
    for keyword in _SENSITIVE_KEYWORDS:
        if stripped.startswith(keyword) or f" {keyword}" in stripped:
            # key=value の value 部分だけをマスク
            if "=" in line:
                key_part, _ = line.split("=", 1)
                return f"{key_part}=*****\n"
    return line
