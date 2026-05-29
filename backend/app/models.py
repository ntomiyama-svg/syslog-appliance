"""SQLAlchemy ORM モデル定義。"""

from datetime import datetime
from typing import Optional

from sqlalchemy import DateTime, Integer, String, func
from sqlalchemy.orm import Mapped, mapped_column

from .db import Base


class Device(Base):
    """管理対象機器モデル。syslog 送信元の機器情報を保持する。"""

    __tablename__ = "devices"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)

    # IP アドレス（ユニーク必須）
    ip: Mapped[str] = mapped_column(String(45), unique=True, nullable=False, index=True)

    # 機器の識別情報（すべて任意）
    hostname: Mapped[Optional[str]] = mapped_column(String(255), nullable=True)
    device_name: Mapped[Optional[str]] = mapped_column(String(255), nullable=True)
    group_name: Mapped[Optional[str]] = mapped_column(String(100), nullable=True, index=True)
    location: Mapped[Optional[str]] = mapped_column(String(255), nullable=True)
    description: Mapped[Optional[str]] = mapped_column(String(1000), nullable=True)

    # タイムスタンプ（DB サーバー側で自動設定）
    created_at: Mapped[datetime] = mapped_column(
        DateTime,
        server_default=func.now(),
        nullable=False,
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime,
        server_default=func.now(),
        onupdate=func.now(),
        nullable=False,
    )
