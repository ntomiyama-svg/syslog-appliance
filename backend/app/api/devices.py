"""機器管理 API。/api/v1/devices 配下のエンドポイントを定義する。"""

import logging
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from ..auth import require_auth
from ..db import get_db
from ..models import Device
from ..schemas import DeviceCreate, DeviceResponse, DeviceUpdate

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/v1/devices", tags=["devices"])


@router.get("", response_model=List[DeviceResponse])
def list_devices(
    group_name: Optional[str] = Query(None, description="グループ名でフィルタ"),
    db: Session = Depends(get_db),
    _user: str = Depends(require_auth),
):
    """機器一覧を取得する。group_name クエリパラメータでフィルタ可能。"""
    query = db.query(Device)
    if group_name is not None:
        query = query.filter(Device.group_name == group_name)
    devices = query.order_by(Device.id).all()
    return devices


@router.post("", response_model=DeviceResponse, status_code=status.HTTP_201_CREATED)
def create_device(
    body: DeviceCreate,
    db: Session = Depends(get_db),
    _user: str = Depends(require_auth),
):
    """新しい機器を登録する。IP の重複は 409 を返す。"""
    existing = db.query(Device).filter(Device.ip == body.ip).first()
    if existing:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"IP アドレス '{body.ip}' は既に登録されています（ID: {existing.id}）。",
        )

    device = Device(**body.model_dump())
    db.add(device)
    db.commit()
    db.refresh(device)

    logger.info("機器を登録しました: id=%d ip=%s name=%s", device.id, device.ip, device.device_name)
    return device


@router.get("/{device_id}", response_model=DeviceResponse)
def get_device(
    device_id: int,
    db: Session = Depends(get_db),
    _user: str = Depends(require_auth),
):
    """指定した機器の情報を取得する。存在しない場合は 404 を返す。"""
    device = _get_device_or_404(db, device_id)
    return device


@router.put("/{device_id}", response_model=DeviceResponse)
def update_device(
    device_id: int,
    body: DeviceUpdate,
    db: Session = Depends(get_db),
    _user: str = Depends(require_auth),
):
    """機器情報を更新する。指定されたフィールドのみ更新する。"""
    device = _get_device_or_404(db, device_id)

    # IP 変更時の重複チェック
    update_data = body.model_dump(exclude_unset=True)
    if "ip" in update_data and update_data["ip"] != device.ip:
        conflict = db.query(Device).filter(Device.ip == update_data["ip"]).first()
        if conflict:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail=f"IP アドレス '{update_data['ip']}' は既に別の機器で使われています（ID: {conflict.id}）。",
            )

    for key, value in update_data.items():
        setattr(device, key, value)

    db.commit()
    db.refresh(device)

    logger.info("機器を更新しました: id=%d ip=%s", device.id, device.ip)
    return device


@router.delete("/{device_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_device(
    device_id: int,
    db: Session = Depends(get_db),
    _user: str = Depends(require_auth),
):
    """機器を削除する。存在しない場合は 404 を返す。"""
    device = _get_device_or_404(db, device_id)

    logger.info("機器を削除します: id=%d ip=%s name=%s", device.id, device.ip, device.device_name)
    db.delete(device)
    db.commit()


def _get_device_or_404(db: Session, device_id: int) -> Device:
    """ID で機器を取得し、存在しなければ 404 を送出するヘルパー。"""
    device = db.query(Device).filter(Device.id == device_id).first()
    if device is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"機器 ID {device_id} は存在しません。",
        )
    return device
