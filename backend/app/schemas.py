"""Pydantic v2 スキーマ定義。API のリクエスト・レスポンス型を定義する。"""

from datetime import datetime
from typing import Optional

from pydantic import BaseModel, ConfigDict, Field


class DeviceBase(BaseModel):
    """機器情報の共通フィールド。"""

    hostname: Optional[str] = Field(None, max_length=255, description="ホスト名")
    device_name: Optional[str] = Field(None, max_length=255, description="機器名（日本語可）")
    group_name: Optional[str] = Field(None, max_length=100, description="グループ名")
    location: Optional[str] = Field(None, max_length=255, description="設置場所")
    description: Optional[str] = Field(None, max_length=1000, description="備考")


class DeviceCreate(DeviceBase):
    """機器新規作成リクエスト。ip は必須。"""

    ip: str = Field(..., max_length=45, description="IP アドレス（IPv4/IPv6）")


class DeviceUpdate(DeviceBase):
    """機器更新リクエスト。すべてのフィールドがオプショナル。"""

    ip: Optional[str] = Field(None, max_length=45, description="IP アドレス（変更する場合のみ指定）")


class DeviceResponse(DeviceBase):
    """機器情報レスポンス。id とタイムスタンプを含む。"""

    model_config = ConfigDict(from_attributes=True)

    id: int
    ip: str
    created_at: datetime
    updated_at: datetime
