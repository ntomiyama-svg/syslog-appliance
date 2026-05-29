"""データベース接続・初期化モジュール。SQLAlchemy 同期版を使用する。"""

import logging
import os

from sqlalchemy import create_engine, event
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

from . import config

logger = logging.getLogger(__name__)


class Base(DeclarativeBase):
    pass


def _get_engine():
    db_path = config.get_db_path()

    # DB ファイルの親ディレクトリがなければ作成する
    db_dir = os.path.dirname(db_path)
    if db_dir and not os.path.exists(db_dir):
        logger.info("DB ディレクトリを作成します: %s", db_dir)
        os.makedirs(db_dir, exist_ok=True)

    engine = create_engine(
        f"sqlite:///{db_path}",
        connect_args={"check_same_thread": False},
    )

    # SQLite の外部キー制約を有効化
    @event.listens_for(engine, "connect")
    def set_sqlite_pragma(dbapi_connection, _connection_record):
        cursor = dbapi_connection.cursor()
        cursor.execute("PRAGMA foreign_keys=ON")
        cursor.close()

    return engine


engine = _get_engine()
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


def init_db() -> None:
    """テーブルが存在しない場合のみ作成する（冪等）。"""
    # models をここで import することで Base にモデルが登録される
    from . import models  # noqa: F401

    Base.metadata.create_all(bind=engine)
    logger.info("DB 初期化完了: %s", config.get_db_path())


def get_db():
    """FastAPI の Depends で使う DB セッションジェネレータ。"""
    db: Session = SessionLocal()
    try:
        yield db
    finally:
        db.close()
