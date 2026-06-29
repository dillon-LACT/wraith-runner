# AI Onboarding Automation

Automatically signs users into software on their computers using AI — no scripts, no hardcoded button clicks, no brittle UI selectors. The AI looks at the screen like a human would and figures it out.

Built for MSPs who need to onboard dozens or hundreds of users across different apps without babysitting every machine.

---

## The Problem

When you onboard a new user, someone has to sit at (or remote into) their machine and sign them into every app. That's slow, repetitive, and doesn't scale. You can't script it reliably because every app's login screen is slightly different, and they change all the time.

---

## How It Works

1. **You submit a job** — tell the system: sign this user into Zoom on this device, here are their credentials.
2. **The runner picks it up** — a small program running on the user's machine polls for pending jobs assigned to it.
3. **The AI takes over** — it takes a screenshot, looks at the screen, clicks the right buttons, types the credentials, and navigates whatever login flow is in front of it.
4. **You get a result** — success, MFA required, bad credentials, timed out, etc. Posted back to the central API and optionally sent to Slack.

The AI (Claude by Anthropic) can handle variations, unexpected screens, "previously signed in" prompts, SSO flows, and more — because it actually reads the screen instead of relying on fixed coordinates or DOM selectors.

---

## Architecture

```
┌─────────────────────────────┐
│        Your System          │  (ImmyBot, RMM, web portal, etc.)
│   POST /jobs → Central API  │
└────────────┬────────────────┘
             │  job queue (SQLite)
             ▼
┌─────────────────────────────┐
│        Central API          │  Runs in the cloud (any VM)
│  api/main.py  port 8002     │  FastAPI + SQLite
└────────────┬────────────────┘
             │  worker polls every 5 seconds
             ▼
┌─────────────────────────────┐
│     Endpoint Runner         │  Runs on the USER'S machine
│  runner/worker.py           │  Installed via ImmyBot
│                             │
│  1. Claims job              │
│  2. Launches the app        │
│  3. Takes screenshot        │
│  4. Sends to Claude AI      │
│  5. Claude says "click X"   │
│  6. Clicks X                │
│  7. Repeat until done       │
│  8. Posts result back       │
└─────────────────────────────┘
```

The runner never needs an inbound port or VPN — it just calls out to the central API. This means it works through firewalls, NAT, and corporate networks without any special configuration.

---

## Components

### `api/` — Central API
The brain. Runs on a cloud server. Stores jobs, handles authentication, and serves results.

- **Tenants** — your MSP customers. Each gets their own API key.
- **Devices** — individual machines. Each gets a device-specific key used by the runner.
- **Jobs** — sign-in requests with status: `pending → claimed → completed`.

Key endpoints:
- `POST /jobs` — submit a sign-in job (tenant key required)
- `GET /jobs/next` — runner polls this to claim its next job (device key required)
- `POST /jobs/{id}/result` — runner posts back the outcome
- `GET /jobs/{id}` — check job status

Admin endpoints (admin key required):
- `POST /admin/tenants` — create a customer
- `POST /admin/api-keys/tenant` — create a key for submitting jobs
- `POST /admin/api-keys/device` — create a key for a specific machine

### `runner/` — Endpoint Worker
Runs on the user's computer. Polls the central API, executes sign-ins, reports back.

- `worker.py` — the main loop (polls, claims jobs, runs them, posts results)
- `server.py` — local-only mode for testing without the central API
- `apps/` — profiles for each supported app (instructions, success criteria, stop conditions)
- `computer_use/` — screenshot capture, AI loop, action executor

---

## Supported Apps

| App  | SSO | Username/Password | Skip (check state) |
|------|-----|-------------------|--------------------|
| Zoom | ✅  | ✅                | ✅                 |

More apps are added by creating a profile in `runner/apps/` — no code changes needed.

---

## Auth Model

Three levels of API keys:

| Key type | Prefix | Used by | Can do |
|----------|--------|---------|--------|
| Admin | (none) | You, manually | Create tenants and keys |
| Tenant | `ten_` | Your RMM / ImmyBot | Submit jobs, check results |
| Device | `dev_` | Runner on each machine | Poll for jobs, post results |

Each device key is tied to a specific `device_id`. A runner can only pick up jobs addressed to its own device.

---

## Setup

### Central API

```bash
cd api
pip install -r requirements.txt
cp .env.example .env
# Edit .env — set ADMIN_KEY to something long and random
uvicorn main:app --host 0.0.0.0 --port 8002
```

Bootstrap a tenant and keys:
```bash
# Create a tenant
curl -X POST http://your-api/admin/tenants \
  -H "X-API-Key: YOUR_ADMIN_KEY" \
  -d '{"name": "Acme Corp"}'

# Create a tenant key (for submitting jobs)
curl -X POST http://your-api/admin/api-keys/tenant \
  -H "X-API-Key: YOUR_ADMIN_KEY" \
  -d '{"name": "Acme Key", "tenant_id": "..."}'

# Create a device key (one per machine)
curl -X POST http://your-api/admin/api-keys/device \
  -H "X-API-Key: YOUR_ADMIN_KEY" \
  -d '{"name": "ACME-PC-001", "tenant_id": "...", "device_id": "ACME-PC-001"}'
```

### Runner (on the endpoint)

```bash
cd runner
pip install -r requirements.txt
# Set in .env:
#   ANTHROPIC_API_KEY=...
#   WORKER_API_URL=https://your-central-api
#   WORKER_DEVICE_KEY=dev_...
python worker.py
```

In production, deploy via ImmyBot and run as a Windows service.

---

## Submitting a Job

```bash
curl -X POST http://your-api/jobs \
  -H "X-API-Key: ten_..." \
  -H "Content-Type: application/json" \
  -d '{
    "device_id": "ACME-PC-001",
    "client": "Acme Corp",
    "user": "jane@acme.com",
    "app": "zoom",
    "method": "sso",
    "sso_domain": "acmecorp"
  }'
```

Result statuses you'll get back:

| Status | Meaning |
|--------|---------|
| `success` | Signed in |
| `mfa_required` | Hit MFA prompt — user needs to approve |
| `bad_credential` | Wrong username or password |
| `user_action_required` | Something needs human attention |
| `app_not_installed` | App isn't on this machine |
| `sso_domain_missing` | SSO domain wasn't provided |
| `blocked_consent_prompt` | Admin consent required in the identity provider |
| `timed_out` | Ran out of steps — re-run or investigate |
| `unexpected_screen` | AI saw something it didn't recognize |
| `skipped` | Skip was requested, current state reported |
| `failed_safely` | Something went wrong, no harmful actions taken |

---

## Adding a New App

Create a file in `runner/apps/`, e.g. `teams.py`:

```python
from apps.base import AppProfile
from job import AuthMethod

teams_profile = AppProfile(
    name="Microsoft Teams",
    app_type="desktop",
    supported_methods=[AuthMethod.sso, AuthMethod.user_pass],
    executable_hints=["Teams.exe"],
    launch_command="start ms-teams://",
    sso_instructions="...",
    user_pass_instructions="...",
    skip_instructions="...",
    success_criteria=["Teams home screen visible", ...],
    stop_conditions=["mfa", "authenticator", ...],
)
```

Then register it in `runner/apps/registry.py`:
```python
from apps.teams import teams_profile
_REGISTRY["teams"] = teams_profile
```

That's it. No other code changes needed.
