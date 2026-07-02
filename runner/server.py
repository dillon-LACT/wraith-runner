import ctypes
try:
    ctypes.windll.shcore.SetProcessDpiAwareness(2)  # PROCESS_PER_MONITOR_DPI_AWARE
except Exception:
    try:
        ctypes.windll.user32.SetProcessDPIAware()
    except Exception:
        pass

import logging
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from fastapi import FastAPI, HTTPException
from job import SignInRequest, SignInResult
from apps.registry import get_app, list_apps
from computer_use.loop import run_signin_loop
from config import LOG_LEVEL
import slack

logging.basicConfig(level=LOG_LEVEL, format="%(asctime)s [%(levelname)s] %(name)s: %(message)s")
logger = logging.getLogger(__name__)

app = FastAPI(title="Endpoint Runner", version="0.1.0")


@app.get("/health")
def health():
    return {"status": "ok", "version": "0.1.0"}


@app.get("/apps")
def available_apps():
    return list_apps()


@app.post("/signin/{app_name}", response_model=SignInResult, response_model_exclude={"screenshot_b64"})
def signin(app_name: str, request: SignInRequest):
    profile = get_app(app_name)
    if not profile:
        raise HTTPException(status_code=404, detail=f"App '{app_name}' not registered.")

    if request.method not in profile.supported_methods:
        raise HTTPException(
            status_code=400,
            detail=f"Method '{request.method}' not supported for {app_name}. "
                   f"Supported: {[m.value for m in profile.supported_methods]}",
        )

    logger.info(f"[{request.client}] signin/{app_name} method={request.method} user={request.user}")
    result = run_signin_loop(profile, request)
    logger.info(f"[{request.client}] result={result.status}")
    slack.post_result(request, result)
    return result


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("server:app", host="127.0.0.1", port=8000, reload=False)
