from fastapi import Header, HTTPException
from config import ADMIN_KEY
import database


def require_admin(x_api_key: str = Header(...)) -> bool:
    if x_api_key != ADMIN_KEY:
        raise HTTPException(401, "Invalid admin key")
    return True


def require_tenant(x_api_key: str = Header(...)) -> dict:
    with database.get_conn() as conn:
        row = conn.execute(
            "SELECT * FROM api_keys WHERE key=? AND type='tenant'", (x_api_key,)
        ).fetchone()
    if not row:
        raise HTTPException(401, "Invalid tenant API key")
    return dict(row)


def require_device(x_api_key: str = Header(...)) -> dict:
    with database.get_conn() as conn:
        row = conn.execute(
            "SELECT * FROM api_keys WHERE key=? AND type='device'", (x_api_key,)
        ).fetchone()
    if not row:
        raise HTTPException(401, "Invalid device API key")
    return dict(row)
