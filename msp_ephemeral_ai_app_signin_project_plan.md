# MSP Ephemeral AI App Sign-In Runner — Project Plan

## Project Name

**Ephemeral AI App Sign-In Runner**

## Mission

Build a sellable MSP product that can temporarily deploy to a Windows endpoint, open required applications, attempt app sign-in using client-specific credentials or SSO metadata, report results to Slack, and remove itself afterward.

The system should not be a brittle script collection. It should include an LLM-assisted decision layer that can observe the screen/UI state, reason through unexpected login flow changes, choose safe next actions, or escalate to a technician through Slack.

---

## 1. Core Workflow

```text
Client app profile
    ↓
Technician/orchestrator selects client + device + user
    ↓
Product resolves required app sign-ins
    ↓
Product retrieves app metadata / credential / SSO info from ITGlue
    ↓
ImmyBot deploys temporary endpoint runner
    ↓
Runner launches in logged-in user session
    ↓
Runner opens apps and attempts sign-in
    ↓
Runner uses LLM decision loop when flow diverges
    ↓
Runner reports status to Slack
    ↓
Runner closes and removes itself
```

---

## 2. Non-Negotiable Requirements

### Endpoint Runner

The runner must:

- Be deployable through ImmyBot/RMM.
- Run on the target endpoint.
- Operate in the interactive/logged-in user session.
- Open/click/type in local Windows apps and browsers.
- Handle local, browser, and hybrid desktop-to-browser SSO flows.
- Report status to Slack.
- Close and self-remove after completion.
- Avoid leaving credential material, local configs, or sensitive logs behind.

### App Profiles

Each client must be able to define which apps need sign-in.

Each app profile should support:

- App name
- App type:
  - Desktop app
  - Browser app
  - Hybrid desktop/browser SSO
- Executable hints
- Login method
- Login URL
- SSO domain / tenant / workspace
- Credential source
- Expected login path
- Success criteria
- Stop conditions
- Client-specific notes

### Credential Sources

Credentials and metadata may come from:

- Technician/workflow input
- ITGlue Passwords
- ITGlue Flexible Assets
- ITGlue Configurations
- Per-client app profile notes

The endpoint runner should not receive broad ITGlue or Slack credentials. The product backend should broker scoped job context.

### Slack Reporting

Slack report should include:

- Client
- Device
- User
- App
- Final status
- Safe troubleshooting notes
- Next action if needed

Example statuses:

- Success
- MFA required
- User action required
- Bad credential
- App not installed
- App opened but login path unknown
- SSO domain missing
- Blocked by consent prompt
- Timed out
- Unexpected screen
- Failed safely

---

## 3. Agentic Decision Layer

This cannot be stupid scripts.

The runner needs an observe → reason → act → verify loop.

```text
Observe current screen/UI state
    ↓
Compare against expected app profile
    ↓
If expected path is clear, continue
    ↓
If flow diverges, send rich context to LLM
    ↓
LLM chooses next safe action or escalates
    ↓
Runner validates and executes action
    ↓
Verify outcome
```

The LLM should receive context such as:

- Current screenshot
- Current UI/accessibility tree if available
- Active window/app
- Visible text/buttons/fields
- Client-specific ITGlue notes
- App-specific instructions
- Prior steps attempted
- Allowed actions
- Stop conditions
- Success criteria

The agent should stop and report to Slack if it sees:

- MFA prompt
- Password reset prompt
- Admin consent prompt
- CAPTCHA
- Terms acceptance
- Payment screen
- Destructive action
- Unknown security prompt
- Anything outside the target app/browser context

---

## 4. Product Shape

This should become a sellable product, not a fragile internal script pile.

### Customer-Facing Product

The customer should see:

```text
Your SaaS/control plane
    + ITGlue integration
    + Slack integration
    + model provider option
    + app profile management
    + generated Immy/RMM deployment task
    + signed ephemeral Windows runner
```

The customer should not need to manually assemble five unrelated tools.

### Customer Setup

Minimum customer setup should be:

1. Connect ITGlue.
2. Connect Slack.
3. Choose managed AI or bring their own OpenAI/Anthropic key.
4. Create/import the generated ImmyBot deployment task.
5. Define per-client app sign-in profiles.
6. Run jobs.

---

## 5. Recommended Architecture

### Control Plane

The SaaS/control plane owns:

- Customer tenants
- Client mappings
- App profiles
- ITGlue integration
- Slack integration
- Job creation
- Job state
- Audit logs
- Secrets brokering
- Model provider routing
- Runner versioning
- Safe action policy

### Endpoint Runner

The signed endpoint runner is a **local FastAPI service** that exposes:

- Per-app sign-in endpoints: `POST /signin/{app}`
- MCP tools over Streamable HTTP (same process, same logic)
- A structured job model with auth method per app: `sso`, `user_pass`, or `skip`

This means ImmyBot, control plane scripts, and Claude agents all call the same runner the same way — HTTP POST or MCP tool call.

The runner owns:

- One-time job authentication
- Local app/browser interaction (pyautogui)
- Screenshot + accessibility tree capture
- LLM computer-use decision loop (Claude, Anthropic API)
- Structured result reporting
- Cleanup/self-removal

The endpoint runner should receive a short-lived job token, not permanent ITGlue, Slack, or LLM API credentials.

See `endpoint_runner_impl.md` for full technical spec.

### Suggested Stack

#### MVP / Same-Day Proof

- Python 3.11+
- FastAPI + uvicorn
- Anthropic API (claude-opus-4-8, computer-use beta)
- pyautogui + Pillow (screenshot, mouse, keyboard)
- pywinauto (accessibility tree, best-effort)
- mcp[cli] (MCP server + tool registration)
- Local job payload via POST body
- Manual HTTP test first, then ImmyBot deployment

#### Product Direction

- SaaS/control plane
- Signed Windows runner (packaged FastAPI service)
- Same runner API called by ImmyBot, control plane, and Claude agents
- ITGlue integration (credential + app profile brokering)
- Slack app/bot integration
- ImmyBot/RMM deployment templates

---

## 6. First Step

### Do This First

**Build the smallest possible Zoom proof of concept on one disposable/internal Windows test machine.**

Do not start with ITGlue.  
Do not start with full SaaS.  
Do not start with packaging.  
Do not start with multi-client logic.

Start with:

```text
One machine
One logged-in user
One known Zoom SSO domain
One Slack webhook
One local job JSON
One AI GUI agent
```

### Goal

Prove that an LLM-guided Windows GUI agent can:

1. Open Zoom desktop.
2. Find the sign-in path.
3. Choose SSO.
4. Enter the known SSO domain.
5. Follow the default-browser SSO redirect.
6. Stop safely at MFA or user action.
7. Report the result to Slack.

---

## 7. Same-Day Zoom MVP Plan

### Step 1 — Prepare Test Environment

Use an internal/disposable Windows test machine.

Requirements:

- Zoom installed.
- User logged into Windows interactively.
- Default browser set.
- Test client SSO domain known.
- Slack incoming webhook created.
- OpenAI or Anthropic API key available.
- Python available if testing Windows-Use.

### Step 2 — Create Local Job Profile

Create a local `job.json` like:

```json
{
  "client": "Test Client",
  "device": "TEST-WIN-01",
  "user": "testuser@example.com",
  "slack_webhook": "https://hooks.slack.com/services/REDACTED",
  "apps": [
    {
      "name": "Zoom",
      "app_type": "desktop_hybrid_sso",
      "login_method": "sso",
      "sso_domain": "exampleclient",
      "success_criteria": [
        "Zoom main window visible",
        "signed-in user profile/avatar visible",
        "no sign-in button visible"
      ],
      "stop_conditions": [
        "MFA prompt",
        "password reset",
        "admin consent",
        "CAPTCHA",
        "terms acceptance",
        "unexpected security prompt"
      ]
    }
  ]
}
```

### Step 3 — Stand Up Local Runner API

Start the FastAPI runner locally (`uvicorn server:app`).

Send a test job via HTTP POST:

```json
POST http://localhost:8000/signin/zoom
{
  "client": "Test Client",
  "device": "TEST-WIN-01",
  "user": "testuser@example.com",
  "method": "sso",
  "sso_domain": "exampleclient"
}
```

The runner opens Zoom, runs the LLM computer-use loop, and returns a `SignInResult`.

See `endpoint_runner_impl.md` for the full loop design, app profile structure, and build order.

### Step 4 — Add Slack Result

For the first version, Slack can be a simple webhook post.

Example result payload:

```json
{
  "text": "Zoom sign-in test complete\nClient: Test Client\nDevice: TEST-WIN-01\nUser: testuser@example.com\nStatus: MFA required\nNext action: User must approve MFA or tech must take over."
}
```

### Step 5 — Move to ImmyBot

Once manual local execution works:

- Package the test runner folder.
- Deploy it through ImmyBot.
- Run it in user context, not only SYSTEM context.
- Confirm it can interact with the visible desktop session.
- Confirm Slack receives the result.

### Step 6 — Add Cleanup

After the run:

- Stop the agent process.
- Delete temp folder.
- Remove local job payload.
- Remove logs with sensitive data.
- Leave only sanitized status if needed.

---

## 8. MVP Success Criteria

The first Zoom MVP is successful if:

- The runner starts on a logged-in Windows session.
- It opens Zoom desktop.
- It finds SSO/company sign-in.
- It enters the SSO domain.
- It follows browser redirect if needed.
- It stops safely at MFA/user action.
- It posts a Slack result.
- It can be removed afterward.

---

## 9. Next Milestones

### Milestone 1 — Zoom Local POC

Manual/local runner on one machine.

### Milestone 2 — Zoom via ImmyBot

Same POC launched through ImmyBot in user context.

### Milestone 3 — ITGlue Metadata

Replace local `job.json` with job context generated from ITGlue app profile fields.

### Milestone 4 — Slack App

Replace webhook with Slack app/bot for richer reporting and technician DMs.

### Milestone 5 — Signed Ephemeral Runner

Package the runner as a signed executable or installer.

### Milestone 6 — Product Control Plane

Build SaaS/control plane for app profiles, job creation, runner downloads, logs, and integration setup.

### Milestone 7 — Multi-App Client Profiles

Add support for more apps:

- Slack
- Adobe Creative Cloud
- OneDrive
- Office activation
- Egnyte
- Dropbox
- Chrome profile sign-in

---

## 10. Current Recommendation

Start today with:

```text
Windows-Use or similar Windows GUI agent
+ Zoom desktop
+ known SSO domain
+ Slack webhook
+ one internal test machine
```

Then graduate to:

```text
ImmyBot user-context deployment
+ Cua Driver/product-grade runner
+ ITGlue app profiles
+ Slack app
+ SaaS control plane
```

The first win is not the whole product.

The first win is proving:

```text
AI can open Zoom, handle desktop-to-browser SSO, stop safely, and tell Slack what happened.
```
