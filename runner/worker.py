import logging
import os
import sys
import time

import requests

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from apps.registry import get_app
from computer_use.loop import run_signin_loop
from config import LOG_LEVEL, WORKER_API_URL, WORKER_DEVICE_KEY, WORKER_POLL_INTERVAL
from job import AuthMethod, SignInRequest
import slack

logging.basicConfig(level=LOG_LEVEL, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
logger = logging.getLogger(__name__)

_headers = {"X-API-Key": WORKER_DEVICE_KEY}


def poll_once() -> None:
    try:
        resp = requests.get(f"{WORKER_API_URL}/jobs/next", headers=_headers, timeout=10)
        resp.raise_for_status()
        job = resp.json()
    except Exception as e:
        logger.warning(f"Poll failed: {e}")
        return

    if not job:
        return

    job_id = job["id"]
    logger.info(f"Claimed job {job_id} — {job['app']}/{job['method']} for {job['user']}")

    profile = get_app(job["app"])
    if not profile:
        _post_result(job_id, "failed_safely", f"App '{job['app']}' not registered on this runner.")
        return

    request = SignInRequest(
        client=job["client"],
        device=job["device_id"],
        user=job["user"],
        app=job["app"],
        method=AuthMethod(job["method"]),
        username=job.get("username"),
        password=job.get("password"),
        sso_domain=job.get("sso_domain"),
        notes=job.get("notes"),
        slack_webhook=job.get("slack_webhook"),
    )

    result = run_signin_loop(profile, request)
    slack.post_result(request, result)
    _post_result(job_id, result.status, result.detail)


def _post_result(job_id: str, status: str, detail: str | None) -> None:
    try:
        resp = requests.post(
            f"{WORKER_API_URL}/jobs/{job_id}/result",
            json={"status": status, "detail": detail},
            headers=_headers,
            timeout=10,
        )
        resp.raise_for_status()
        logger.info(f"Job {job_id} result posted: {status}")
    except Exception as e:
        logger.error(f"Failed to post result for job {job_id}: {e}")


def main() -> None:
    if not WORKER_DEVICE_KEY:
        logger.error("WORKER_DEVICE_KEY not set — exiting")
        sys.exit(1)
    logger.info(f"Worker started — polling {WORKER_API_URL} every {WORKER_POLL_INTERVAL}s")
    while True:
        poll_once()
        time.sleep(WORKER_POLL_INTERVAL)


if __name__ == "__main__":
    main()
