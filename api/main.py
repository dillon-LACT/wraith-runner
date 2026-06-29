import uuid
import logging
from datetime import datetime, timezone
from typing import Optional

from fastapi import FastAPI, Depends, HTTPException
from pydantic import BaseModel

import auth
import database

logging.basicConfig(level="INFO", format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
logger = logging.getLogger(__name__)

app = FastAPI(title="Onboarding Automation API", version="0.1.0")


@app.on_event("startup")
def startup():
    database.init_db()
    logger.info("Database initialized")


# ---------- request/response models ----------

class CreateTenant(BaseModel):
    name: str

class CreateKeyRequest(BaseModel):
    name: str
    tenant_id: str
    device_id: Optional[str] = None

class CreateJob(BaseModel):
    device_id: str
    client: str
    user: str
    app: str
    method: str
    username: Optional[str] = None
    password: Optional[str] = None
    sso_domain: Optional[str] = None
    notes: Optional[str] = None
    slack_webhook: Optional[str] = None

class JobResult(BaseModel):
    status: str
    detail: Optional[str] = None


# ---------- admin ----------

@app.post("/admin/tenants")
def create_tenant(body: CreateTenant, _=Depends(auth.require_admin)):
    tenant_id = str(uuid.uuid4())
    with database.get_conn() as conn:
        conn.execute("INSERT INTO tenants VALUES (?,?,?)", (tenant_id, body.name, _now()))
    return {"tenant_id": tenant_id}


@app.post("/admin/api-keys/tenant")
def create_tenant_key(body: CreateKeyRequest, _=Depends(auth.require_admin)):
    key = "ten_" + uuid.uuid4().hex
    with database.get_conn() as conn:
        conn.execute(
            "INSERT INTO api_keys VALUES (?,?,?,?,?,?)",
            (key, body.name, "tenant", body.tenant_id, None, _now()),
        )
    return {"api_key": key}


@app.post("/admin/api-keys/device")
def create_device_key(body: CreateKeyRequest, _=Depends(auth.require_admin)):
    if not body.device_id:
        raise HTTPException(400, "device_id required for device keys")
    key = "dev_" + uuid.uuid4().hex
    with database.get_conn() as conn:
        conn.execute(
            "INSERT INTO api_keys VALUES (?,?,?,?,?,?)",
            (key, body.name, "device", body.tenant_id, body.device_id, _now()),
        )
    return {"api_key": key, "device_id": body.device_id}


# ---------- tenant (job submission) ----------

@app.post("/jobs", status_code=201)
def create_job(body: CreateJob, key_info=Depends(auth.require_tenant)):
    job_id = str(uuid.uuid4())
    with database.get_conn() as conn:
        conn.execute(
            """INSERT INTO jobs
               (id, tenant_id, device_id, client, user, app, method,
                username, password, sso_domain, notes, slack_webhook,
                status, result_status, result_detail, created_at, claimed_at, completed_at)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,'pending',NULL,NULL,?,NULL,NULL)""",
            (job_id, key_info["tenant_id"], body.device_id, body.client, body.user,
             body.app, body.method, body.username, body.password,
             body.sso_domain, body.notes, body.slack_webhook, _now()),
        )
    logger.info(f"Job {job_id} created — {body.app}/{body.method} → device {body.device_id}")
    return {"job_id": job_id, "status": "pending"}


# ---------- device (runner polling) ----------

@app.get("/jobs/next")
def next_job(key_info=Depends(auth.require_device)):
    device_id = key_info["device_id"]
    with database.get_conn() as conn:
        row = conn.execute(
            "SELECT * FROM jobs WHERE device_id=? AND status='pending' ORDER BY created_at LIMIT 1",
            (device_id,),
        ).fetchone()
        if not row:
            return None
        updated = conn.execute(
            "UPDATE jobs SET status='claimed', claimed_at=? WHERE id=? AND status='pending'",
            (_now(), row["id"]),
        ).rowcount
    if not updated:
        return None
    logger.info(f"Job {row['id']} claimed by device {device_id}")
    return dict(row)


@app.post("/jobs/{job_id}/result")
def post_result(job_id: str, body: JobResult, key_info=Depends(auth.require_device)):
    with database.get_conn() as conn:
        updated = conn.execute(
            """UPDATE jobs SET status='completed', result_status=?, result_detail=?, completed_at=?
               WHERE id=? AND device_id=?""",
            (body.status, body.detail, _now(), job_id, key_info["device_id"]),
        ).rowcount
    if not updated:
        raise HTTPException(404, "Job not found or not owned by this device")
    logger.info(f"Job {job_id} completed — {body.status}")
    return {"ok": True}


@app.get("/jobs/{job_id}")
def get_job(job_id: str, key_info=Depends(auth.require_tenant)):
    with database.get_conn() as conn:
        row = conn.execute(
            "SELECT * FROM jobs WHERE id=? AND tenant_id=?",
            (job_id, key_info["tenant_id"]),
        ).fetchone()
    if not row:
        raise HTTPException(404, "Job not found")
    return _safe_job(dict(row))


@app.get("/health")
def health():
    return {"status": "ok", "version": "0.1.0"}


# ---------- helpers ----------

def _now() -> str:
    return datetime.now(timezone.utc).isoformat()

def _safe_job(job: dict) -> dict:
    job.pop("password", None)
    return job
