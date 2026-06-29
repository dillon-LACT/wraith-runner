import json
import logging
import re
import subprocess
import time

import anthropic

from apps.base import AppProfile
from computer_use.capture import capture_screenshot, focus_primary
from computer_use.executor import execute_action
from config import ANTHROPIC_API_KEY, CU_BETA, CU_MODEL, CU_TOOL_TYPE, RUNNER_MAX_STEPS, RUNNER_STEP_DELAY_MS
from job import AuthMethod, SignInRequest, SignInResult

logger = logging.getLogger(__name__)
_client = anthropic.Anthropic(api_key=ANTHROPIC_API_KEY)

_VALID_STATUSES = {
    "success", "mfa_required", "user_action_required", "bad_credential",
    "app_not_installed", "login_path_unknown", "sso_domain_missing",
    "blocked_consent_prompt", "timed_out", "unexpected_screen", "skipped", "failed_safely",
}


def _build_system_prompt(profile: AppProfile, request: SignInRequest) -> str:
    if request.method == AuthMethod.sso:
        instructions = profile.sso_instructions
    elif request.method == AuthMethod.user_pass:
        instructions = profile.user_pass_instructions
    else:
        instructions = profile.skip_instructions

    creds = ""
    if request.sso_domain:
        creds += f"\n- SSO domain: {request.sso_domain}"
    if request.username:
        creds += f"\n- Username: {request.username}"
    if request.password:
        creds += f"\n- Password: {request.password}"
    if request.notes:
        creds += f"\n- Client notes: {request.notes}"

    success = "\n".join(f"- {c}" for c in profile.success_criteria)
    stops = "\n".join(f"- {c}" for c in profile.stop_conditions)

    return f"""You are a Windows GUI automation agent running on a client endpoint.
Your task is to sign a user into {profile.name} and report the outcome.

Job:
- Client: {request.client}
- Device: {request.device}
- User: {request.user}
- App: {profile.name}
- Auth method: {request.method.value}{creds}

Instructions:
{instructions}

Success criteria — if any of these are true, report status "success":
{success}

Stop conditions — if you see any of these, stop immediately without clicking:
{stops}

Safety rules (non-negotiable):
- Never approve MFA, 2FA, or any authenticator prompt.
- Never change or reset a password.
- Never click outside the target app or its sign-in browser flow.
- Never interact with unrelated windows, tabs, or applications.
- Never proceed past a consent screen, CAPTCHA, or security prompt.

When you are done or blocked, output ONLY this JSON on the last line of your response:
{{"status": "<status>", "detail": "<one sentence explanation>"}}

Valid status values: success, mfa_required, user_action_required, bad_credential,
app_not_installed, login_path_unknown, sso_domain_missing, blocked_consent_prompt,
timed_out, unexpected_screen, skipped, failed_safely
"""


def _parse_result(text: str, app: str, method: AuthMethod) -> SignInResult | None:
    match = re.search(r'\{[^{}]*"status"\s*:\s*"([^"]+)"[^{}]*\}', text, re.DOTALL)
    if not match:
        return None
    try:
        data = json.loads(match.group())
        status = data.get("status", "failed_safely")
        if status not in _VALID_STATUSES:
            status = "failed_safely"
        return SignInResult(app=app, method=method, status=status, detail=data.get("detail"))
    except json.JSONDecodeError:
        return None


def _stop_condition_hit(screenshot_b64: str, stop_conditions: list[str]) -> bool:
    """
    Placeholder for a fast local check before involving the LLM.
    For now returns False — the LLM enforces stops via its prompt.
    A future version could run a lightweight OCR pass here.
    """
    return False


def _prune_screenshots(messages: list[dict]) -> None:
    """Replace all but the most recent screenshot with a text placeholder to keep API payloads small."""
    last_idx = -1
    for i, msg in enumerate(messages):
        if msg["role"] != "user":
            continue
        content = msg["content"]
        if not isinstance(content, list):
            continue
        for item in content:
            if isinstance(item, dict) and item.get("type") == "tool_result":
                inner = item.get("content", [])
                if isinstance(inner, list) and any(c.get("type") == "image" for c in inner):
                    last_idx = i

    for i, msg in enumerate(messages):
        if i == last_idx or msg["role"] != "user":
            continue
        content = msg["content"]
        if not isinstance(content, list):
            continue
        for item in content:
            if isinstance(item, dict) and item.get("type") == "tool_result":
                inner = item.get("content", [])
                if isinstance(inner, list) and any(c.get("type") == "image" for c in inner):
                    item["content"] = [{"type": "text", "text": "[screenshot removed]"}]


def run_signin_loop(profile: AppProfile, request: SignInRequest) -> SignInResult:
    if profile.launch_command:
        for exe in profile.executable_hints:
            subprocess.Popen(["taskkill", "/f", "/im", exe],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(1)
        logger.info(f"Launching app: {profile.launch_command}")
        subprocess.Popen(["pwsh", "-Command", profile.launch_command])
        time.sleep(3)

    focus_primary(profile.name)
    time.sleep(1)
    screenshot_b64, width, height = capture_screenshot()

    computer_tool = {
        "type": CU_TOOL_TYPE,
        "name": "computer",
        "display_width_px": width,
        "display_height_px": height,
    }

    system_prompt = _build_system_prompt(profile, request)

    messages: list[dict] = [
        {
            "role": "user",
            "content": [
                {
                    "type": "image",
                    "source": {"type": "base64", "media_type": "image/png", "data": screenshot_b64},
                },
                {
                    "type": "text",
                    "text": f"Current screen. Sign {request.user} into {profile.name} using {request.method.value}. Begin.",
                },
            ],
        }
    ]

    final_screenshot = screenshot_b64

    for step in range(RUNNER_MAX_STEPS):
        logger.info(f"Step {step + 1}/{RUNNER_MAX_STEPS}")

        response = _client.beta.messages.create(
            model=CU_MODEL,
            max_tokens=4096,
            system=system_prompt,
            tools=[computer_tool],
            messages=messages,
            betas=[CU_BETA],
        )

        messages.append({"role": "assistant", "content": response.content})

        # Check text blocks for a result declaration
        for block in response.content:
            if hasattr(block, "text") and block.text:
                logger.info(f"Agent text: {block.text[:300]}")
                result = _parse_result(block.text, request.app, request.method)
                if result:
                    result.screenshot_b64 = final_screenshot
                    logger.info(f"Agent declared: {result.status}")
                    return result

        if response.stop_reason == "end_turn":
            logger.warning("Agent reached end_turn without declaring a status.")
            return SignInResult(
                app=request.app,
                method=request.method,
                status="failed_safely",
                detail="Agent finished without reporting a status.",
                screenshot_b64=final_screenshot,
            )

        # Execute tool_use actions
        tool_results = []
        for block in response.content:
            if block.type != "tool_use":
                continue

            action = block.input
            action_type = action.get("action")
            logger.info(f"Action: {action_type} {action}")

            if action_type == "screenshot":
                focus_primary(profile.name)
                time.sleep(0.5)
                ss, w, h = capture_screenshot()
                final_screenshot = ss
                tool_results.append({
                    "type": "tool_result",
                    "tool_use_id": block.id,
                    "content": [
                        {
                            "type": "image",
                            "source": {"type": "base64", "media_type": "image/png", "data": ss},
                        }
                    ],
                })
            else:
                result_str = execute_action(action)
                time.sleep(RUNNER_STEP_DELAY_MS / 1000)
                tool_results.append({
                    "type": "tool_result",
                    "tool_use_id": block.id,
                    "content": result_str,
                })

        if tool_results:
            messages.append({"role": "user", "content": tool_results})
            _prune_screenshots(messages)

    ss, _, _ = capture_screenshot()
    return SignInResult(
        app=request.app,
        method=request.method,
        status="timed_out",
        detail=f"Did not complete within {RUNNER_MAX_STEPS} steps.",
        screenshot_b64=ss,
    )
