# Endpoint Runner — Implementation Spec

## Architecture Decision

The runner is **not a standalone script**. It is a local FastAPI service that:

- Exposes per-app sign-in endpoints (REST + MCP tools over the same server)
- Accepts structured job parameters (app, auth method, credentials)
- Runs an LLM-guided computer-use loop to execute the sign-in
- Returns structured results

This means Claude Code, ImmyBot scripts, or any agent can call it as an MCP tool or a plain HTTP POST — and the runner itself uses Claude to reason through whatever the screen throws at it.

---

## Why FastAPI + MCP Together

An MCP server exposes tools that any Claude agent can call directly. A FastAPI server exposes the same logic as HTTP endpoints that ImmyBot, scripts, and external systems can call. Running both from one process gives you both without duplicating logic.

Transport: **Streamable HTTP** (MCP over HTTP, not stdio). This works locally on the endpoint and survives deployment through ImmyBot without needing stdin/stdout piping.

---

## Auth Methods Per App

Every app endpoint accepts one of three methods:

| Method | What it means |
|---|---|
| `sso` | Enter SSO domain, follow browser redirect, stop at MFA |
| `user_pass` | Type username and password directly into the app |
| `skip` | App is already signed in or should not be touched — report current state only |

The method is passed in the job payload. The computer-use agent adjusts its instructions and stop conditions based on the method.

---

## Directory Structure

```
runner/
├── server.py              # FastAPI app + MCP server registration
├── config.py              # Env vars (ANTHROPIC_API_KEY, etc.)
├── job.py                 # Job/result Pydantic models
├── computer_use/
│   ├── loop.py            # Core observe → reason → act → verify loop
│   ├── capture.py         # Screenshot + accessibility tree capture
│   └── executor.py        # pyautogui action executor (click, type, scroll, key)
├── apps/
│   ├── base.py            # AppProfile base class
│   ├── zoom.py            # Zoom-specific profile, instructions, stop conditions
│   └── registry.py        # Maps app name → AppProfile class
├── tools/
│   └── mcp_tools.py       # MCP tool definitions (thin wrappers over app handlers)
└── requirements.txt
```

---

## Core Models

```python
# job.py

class AuthMethod(str, Enum):
    sso = "sso"
    user_pass = "user_pass"
    skip = "skip"

class SignInRequest(BaseModel):
    client: str
    device: str
    user: str
    app: str                        # maps to registry key ("zoom", "slack", etc.)
    method: AuthMethod
    sso_domain: str | None = None
    username: str | None = None
    password: str | None = None     # short-lived, never logged
    notes: str | None = None        # client-specific ITGlue notes passed through

class SignInResult(BaseModel):
    app: str
    method: AuthMethod
    status: str                     # see status list below
    detail: str | None = None
    screenshot_b64: str | None = None   # final screenshot for Slack report
```

### Status values

```
success
mfa_required
user_action_required
bad_credential
app_not_installed
login_path_unknown
sso_domain_missing
blocked_consent_prompt
timed_out
unexpected_screen
skipped
failed_safely
```

---

## FastAPI Endpoints

```
POST /signin/{app}
    Body: SignInRequest
    Returns: SignInResult

GET /health
    Returns: { status: "ok", version: "..." }

GET /apps
    Returns: list of registered app names + supported methods
```

The `{app}` path param maps to the app registry. Unknown apps return 404.

---

## MCP Tool Registration

The same `POST /signin/{app}` logic is exposed as an MCP tool called `signin_app`:

```
Tool: signin_app
Description: Sign a user into a desktop or browser app on this endpoint using the specified auth method.
Parameters:
  - app: string (required) — app name, e.g. "zoom"
  - method: "sso" | "user_pass" | "skip" (required)
  - client: string (required)
  - user: string (required)
  - sso_domain: string (optional)
  - username: string (optional)
  - password: string (optional)
  - notes: string (optional)
Returns: SignInResult JSON
```

This means Claude Code can call `signin_app` as a tool directly during an agent session, and the runner handles all screen interaction.

---

## Computer-Use Loop

```python
# computer_use/loop.py (pseudocode)

def run_signin_loop(profile: AppProfile, request: SignInRequest) -> SignInResult:
    messages = [build_system_prompt(profile, request)]
    
    for step in range(MAX_STEPS):
        screenshot = capture_screen()
        accessibility = capture_accessibility_tree()  # best-effort
        
        messages.append(build_user_turn(screenshot, accessibility, step))
        
        response = anthropic_client.beta.messages.create(
            model="claude-opus-4-8",
            tools=[computer_use_tool],
            messages=messages,
            betas=["computer-use-2025-01-01"],
        )
        
        # Check if agent declared done or needs to stop
        if response.stop_reason == "end_turn":
            return parse_final_result(response)
        
        # Execute all tool_use blocks
        for block in response.content:
            if block.type == "tool_use":
                action_result = execute_action(block.input)
                messages.append(build_tool_result(block.id, action_result))
        
        # Hard stop condition check (enforced outside LLM)
        if any_stop_condition_visible(screenshot, profile.stop_conditions):
            return SignInResult(status="user_action_required", ...)
    
    return SignInResult(status="timed_out", ...)
```

Stop conditions are enforced at **two layers**:
1. The LLM prompt instructs the model to stop and report
2. The loop independently checks for known stop-condition keywords/patterns and can halt without waiting for an LLM turn — prevents runaway behavior on security prompts

---

## App Profile Schema

```python
# apps/base.py

@dataclass
class AppProfile:
    name: str
    app_type: Literal["desktop", "browser", "hybrid"]
    supported_methods: list[AuthMethod]
    executable_hints: list[str]          # process names to look for / launch
    launch_command: str | None           # how to open if not running
    
    # Per-method instructions (injected into LLM system prompt)
    sso_instructions: str | None
    user_pass_instructions: str | None
    skip_instructions: str | None
    
    success_criteria: list[str]          # what "done" looks like
    stop_conditions: list[str]           # hard stops
    post_signin_verification: str | None # optional extra check after success
```

---

## Zoom App Profile (Today's Target)

```python
# apps/zoom.py

zoom_profile = AppProfile(
    name="zoom",
    app_type="hybrid",
    supported_methods=[AuthMethod.sso, AuthMethod.user_pass, AuthMethod.skip],
    executable_hints=["Zoom.exe", "zoom.exe"],
    launch_command="start zoommtg://",  # or find + launch .exe

    sso_instructions="""
        Open Zoom. If already signed in, report success immediately.
        Click Sign In. Choose 'Sign In with SSO' or 'Company Domain'.
        Enter the SSO domain from the job profile.
        Click Continue. The default browser will open.
        Follow the browser SSO redirect. Do not interact with unrelated browser tabs.
        Stop immediately if you see MFA, a password prompt, admin consent, CAPTCHA,
        terms acceptance, or any unexpected security prompt.
        Do not approve anything. Report the exact screen state.
    """,

    success_criteria=[
        "Zoom main window visible",
        "user profile picture or avatar visible",
        "no sign-in button visible",
        "home, meetings, or chat tab visible",
    ],

    stop_conditions=[
        "MFA", "multi-factor", "authenticator", "verify your identity",
        "password reset", "change your password",
        "admin consent", "approve permissions",
        "CAPTCHA", "prove you're not a robot",
        "terms of service", "terms and conditions",
        "payment", "billing",
        "unexpected error", "something went wrong",
    ],
)
```

---

## System Prompt Structure

The LLM system prompt is assembled per job run from:

1. **Role**: You are a Windows GUI automation agent running on a client endpoint.
2. **Job context**: client, device, user, app, method
3. **App-specific instructions**: from the app profile's method-specific block
4. **Success criteria**: what done looks like
5. **Stop conditions**: what to halt on immediately
6. **Safety rules**: never approve MFA, never change passwords, never access unrelated apps, never click outside the target app/browser context
7. **Output format**: how to declare status when done

---

## Stack

```
Python 3.11+
fastapi
uvicorn
anthropic          # claude-opus-4-8, computer-use beta
pyautogui          # mouse, keyboard, screenshot
Pillow             # image capture/encoding
pywinauto          # accessibility tree (best-effort)
mcp[cli]           # MCP server + tool registration
pydantic           # models
python-dotenv      # env config
```

---

## Environment Config

```env
ANTHROPIC_API_KEY=sk-ant-...
RUNNER_MAX_STEPS=25
RUNNER_STEP_DELAY_MS=1000
RUNNER_SCREENSHOT_SCALE=0.75   # reduce token cost
LOG_LEVEL=INFO
```

---

## Today's Build Order

1. `requirements.txt` + `config.py`
2. `job.py` — models
3. `computer_use/capture.py` — screenshot to base64
4. `computer_use/executor.py` — pyautogui action dispatch
5. `apps/zoom.py` + `apps/registry.py`
6. `computer_use/loop.py` — the core loop
7. `server.py` — FastAPI + `/signin/zoom` endpoint
8. Manual test: POST to `/signin/zoom` with SSO method
9. `tools/mcp_tools.py` — wrap as MCP tool
10. Test via Claude Code MCP connection

Slack and cleanup come after the loop works end-to-end.

---

## What This Enables Later

- Add a new app: create `apps/slack.py`, register it — endpoint and MCP tool appear automatically
- ImmyBot calls `POST /signin/zoom` over localhost, gets a result JSON, posts it
- Claude Code or any agent calls `signin_app` as an MCP tool during a session
- Control plane sends job payloads to the runner API instead of managing scripts
- Runner is replaced/updated independently of the control plane
