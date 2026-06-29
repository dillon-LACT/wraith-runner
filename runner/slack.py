import json
import logging
import urllib.request

from config import SLACK_WEBHOOK
from job import SignInRequest, SignInResult

logger = logging.getLogger(__name__)

_STATUS_EMOJI = {
    "success": ":white_check_mark:",
    "mfa_required": ":lock:",
    "user_action_required": ":raised_hand:",
    "bad_credential": ":x:",
    "app_not_installed": ":ghost:",
    "login_path_unknown": ":question:",
    "sso_domain_missing": ":warning:",
    "blocked_consent_prompt": ":no_entry:",
    "timed_out": ":hourglass_flowing_sand:",
    "unexpected_screen": ":eyes:",
    "skipped": ":fast_forward:",
    "failed_safely": ":sos:",
}

_NEXT_ACTION = {
    "success": "No action needed.",
    "mfa_required": "User must approve MFA or technician must complete sign-in manually.",
    "user_action_required": "User or technician action required to proceed.",
    "bad_credential": "Check credentials in ITGlue and re-run, or reset the password.",
    "app_not_installed": "Install the app on this device and re-run.",
    "login_path_unknown": "Review the app profile instructions — the login UI may have changed.",
    "sso_domain_missing": "Add the SSO domain to the app profile and re-run.",
    "blocked_consent_prompt": "Admin must grant consent in the identity provider before this can proceed.",
    "timed_out": "Re-run with more steps, or check whether the app is responding normally.",
    "unexpected_screen": "Review the screenshot and update the app profile or escalate.",
    "skipped": "Sign-in was skipped per job profile.",
    "failed_safely": "Check the runner logs for details.",
}


def post_result(request: SignInRequest, result: SignInResult) -> None:
    webhook = request.slack_webhook or SLACK_WEBHOOK
    if not webhook:
        logger.debug("No Slack webhook configured — skipping notification.")
        return

    emoji = _STATUS_EMOJI.get(result.status, ":question:")
    next_action = _NEXT_ACTION.get(result.status, "Check the runner logs.")

    text = (
        f"{emoji} *{result.app} sign-in — {result.status.replace('_', ' ').title()}*\n"
        f">*Client:* {request.client}\n"
        f">*Device:* {request.device}\n"
        f">*User:* {request.user}\n"
        f">*Method:* {result.method.value}\n"
        f">*Detail:* {result.detail or '—'}\n"
        f">*Next action:* {next_action}"
    )

    payload = json.dumps({"text": text}).encode()
    req = urllib.request.Request(
        webhook,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            if resp.status != 200:
                logger.warning(f"Slack webhook returned {resp.status}")
    except Exception as exc:
        logger.warning(f"Slack notification failed: {exc}")
