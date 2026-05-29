"""Basic 認証モジュール。FastAPI の Depends で使用する。"""

import logging
import secrets

from fastapi import Depends, HTTPException, Request, status
from fastapi.security import HTTPBasic, HTTPBasicCredentials

from . import config

logger = logging.getLogger(__name__)

security = HTTPBasic()


def require_auth(
    request: Request,
    credentials: HTTPBasicCredentials = Depends(security),
) -> str:
    """Basic 認証を検証する。認証失敗時は 401 を返す。

    タイミング攻撃対策のため secrets.compare_digest を使う。
    """
    expected_user = config.get_auth_user()
    expected_pass = config.get_auth_pass()

    # パスワード未設定の場合はすべての認証を拒否する（安全側に倒す）
    if not expected_pass:
        logger.warning(
            "認証拒否: AUTH_PASS 未設定 | IP=%s UA=%s",
            _get_client_ip(request),
            request.headers.get("user-agent", "-"),
        )
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="サーバーの認証情報が未設定です。管理者に連絡してください。",
            headers={"WWW-Authenticate": "Basic"},
        )

    # secrets.compare_digest でタイミング攻撃を防ぐ（長さが異なる場合も安全に比較）
    user_ok = secrets.compare_digest(
        credentials.username.encode("utf-8"),
        expected_user.encode("utf-8"),
    )
    pass_ok = secrets.compare_digest(
        credentials.password.encode("utf-8"),
        expected_pass.encode("utf-8"),
    )

    if not (user_ok and pass_ok):
        logger.warning(
            "認証失敗: user=%s | IP=%s UA=%s",
            credentials.username,
            _get_client_ip(request),
            request.headers.get("user-agent", "-"),
        )
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="ユーザー名またはパスワードが正しくありません。",
            headers={"WWW-Authenticate": "Basic"},
        )

    return credentials.username


def _get_client_ip(request: Request) -> str:
    """X-Forwarded-For を優先しつつクライアント IP を返す。"""
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        return forwarded.split(",")[0].strip()
    if request.client:
        return request.client.host
    return "-"
