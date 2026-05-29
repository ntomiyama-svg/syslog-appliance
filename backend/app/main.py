"""syslog-appliance バックエンド FastAPI アプリケーション。"""

import logging
import logging.config

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from . import config
from .db import init_db
from .api import devices, system

# ロギング設定: systemd journal に流れるよう stdout/stderr に出す
logging.basicConfig(
    level=getattr(logging, config.get_log_level(), logging.INFO),
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)

logger = logging.getLogger(__name__)

app = FastAPI(
    title="syslog-appliance Backend API",
    description="syslog アプライアンスの管理 REST API（MVP 1.0）",
    version=config.APP_VERSION,
    docs_url="/docs",
    redoc_url="/redoc",
)

# CORS 設定: 社内 LAN 想定で全許可
# MVP 1.2 で HTTPS 導入時に許可オリジンを絞ること
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# API ルーターを登録
app.include_router(devices.router)
app.include_router(system.router)


@app.on_event("startup")
def on_startup():
    """アプリ起動時の初期化処理。"""
    config.validate_config()
    init_db()
    logger.info(
        "%s v%s 起動完了 | DB=%s",
        config.APP_NAME,
        config.APP_VERSION,
        config.get_db_path(),
    )


@app.get("/healthz", tags=["health"])
def healthz():
    """ヘルスチェックエンドポイント。認証不要。systemd の起動確認に使用。"""
    return {"status": "ok", "version": config.APP_VERSION}
