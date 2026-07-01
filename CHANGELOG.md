# Changelog — AI Onboarding Automation (Wraith Runner)

Internal tracking log. Most recent entries at top.

---

## 2026-06-30

### immybot/install-runner.ps1 — .env BOM fix
- Replaced `Set-Content -Encoding UTF8` with `[System.IO.File]::WriteAllText(..., [System.Text.Encoding]::ASCII)` for writing `.env`
- **Why:** PS5.1 `Set-Content -Encoding UTF8` adds a UTF-8 BOM. `python-dotenv`'s `load_dotenv()` reads the BOM as part of the first key name (`\xef\xbb\xbfANTHROPIC_API_KEY`), so `os.environ["ANTHROPIC_API_KEY"]` raises `KeyError` on startup and the service crashes immediately.
- Same root cause as the `python312._pth` BOM fix — PS5.1 UTF-8 always means UTF-8-with-BOM.
- **Result:** Worker service now starts, loads config, and polls the central API URL.

### Install pipeline — fully working end-to-end (2026-06-30)
- Full install confirmed on DESKTOP-GVA2OP8: Python embeddable → pip → all 92 packages → NSSM → service installed and running
- Worker starts, reads `.env`, polls `WORKER_API_URL` every 5s
- Only remaining gap: central API (Railway) not yet deployed, so polls fail with connection error (expected)

### vendor/ — replaced all tar.gz source dists with pre-built wheels
- `PyAutoGUI-0.9.54.tar.gz` → `pyautogui-0.9.54-py3-none-any.whl`
- `PyGetWindow-0.0.9.tar.gz` → `pygetwindow-0.0.9-py3-none-any.whl`
- `pyscreeze-1.0.1.tar.gz` → `pyscreeze-1.0.1-py3-none-any.whl`
- `pytweening-1.2.0.tar.gz` → `pytweening-1.2.0-py3-none-any.whl`
- `MouseInfo-0.1.3.tar.gz` → `mouseinfo-0.1.3-py3-none-any.whl`
- `PyRect-0.2.0.tar.gz` → `pyrect-0.2.0-py2.py3-none-any.whl`
- **Why:** ImmyBot sessions timed out (~76s) because pip was building these from source on each run (no pip cache in the SYSTEM profile on a fresh machine). Pure-Python wheels install instantly with no build step.
- **Wheels built locally** using `pip wheel <source.tar.gz> --no-deps --wheel-dir vendor/built-wheels`

### vendor/ — added pydantic-core 2.46.4 wheel
- Added `pydantic_core-2.46.4-cp312-cp312-win_amd64.whl` alongside the existing 2.47.0 wheel
- **Why:** `pydantic==2.13.4` pins `pydantic-core==2.46.4` exactly. Only 2.47.0 was in vendor/, causing pip to fail with "Could not find a version that satisfies the requirement pydantic-core==2.46.4"

### runner.zip — rebuilt with correct internal path structure
- Internal paths are now `runner/vendor/...`, `runner/worker.py`, etc.
- Previously paths were bare `vendor/...` (missing the `runner/` prefix)
- **Why:** `Expand-Archive -DestinationPath $installPath` puts files at `C:\ProgramData\OnboardingRunner\<first-entry-name>\`. Without the prefix, vendor/ landed at `C:\ProgramData\OnboardingRunner\vendor\` but the script looks for `C:\ProgramData\OnboardingRunner\runner\vendor\`.
- Uploaded to GitHub release v0.1.0 via `gh release upload v0.1.0 runner.zip --clobber`

### immybot/install-runner.ps1 — pip bootstrap via bundled wheel (no get-pip.py)
- Replaced `get-pip.py` network download with `Expand-Archive` of `pip-*.whl` from vendor/
- **Why:** `get-pip.py` hits `pypi.org/simple/pip/` at the TCP level. pypi.org is TCP-blocked on the target machine (DESKTOP-GVA2OP8).

### immybot/install-runner.ps1 — .whl → .zip copy for Expand-Archive
- Added `Copy-Item $pipWhl "$env:TEMP\pip-install.zip"` before expanding
- **Why:** PS5.1 `Expand-Archive` only accepts `.zip` extension. Feeding it a `.whl` file directly throws: "FAILED: .whl is not a supported archive file format."

### immybot/install-runner.ps1 — pre-install setuptools + wheel before pip
- Added step: `& $pythonExe -m pip install setuptools wheel --no-index --find-links $vendorDir`
- **Why:** Some packages (originally pyautogui deps) are source dists (tar.gz). pip needs a build backend (`setuptools.build_meta`) to process them. Without pre-installing setuptools, pip throws `BackendUnavailable: Cannot import 'setuptools.build_meta'`.

### immybot/install-runner.ps1 — python312._pth BOM fix
- Write `._pth` using `[System.IO.File]::WriteAllText(..., [System.Text.Encoding]::ASCII)` instead of PS `Set-Content -Encoding UTF8`
- **Why:** PS5.1 `Set-Content -Encoding UTF8` adds a UTF-8 BOM. Python's path parser prepends the BOM bytes to "python312.zip", making the stdlib path `\xef\xbb\xbfpython312.zip` which doesn't exist → all imports fail.

### immybot/install-runner.ps1 — file-based Python health check
- Check `Test-Path $pythonExe` + `Test-Path "$pythonDir\python312.zip"` instead of running `python.exe --version`
- **Why:** The broken `python.exe` (with corrupted `._pth`) hangs indefinitely on startup. Running it to check health locks up the ImmyBot session.

### ImmyBot API — documented correct field names and gotchas
- Script content field is `action`, not `scriptContent` (discovered by trial and error)
- Rerun body key is `sessionIds` (array), not `maintenanceSessionId`
- List endpoints (e.g. `/maintenance-sessions?computerId=X`) return the HTML SPA — only per-ID GETs work via API
- Reruns create **new** session IDs (not reusing original) — poll above the last known ID

---

## Architecture snapshot (as of 2026-06-30)

**Target machine:** DESKTOP-GVA2OP8 (computerId=3804, logictcg.immy.bot)
- ImmyBot maintenance session: 1282173 (parent; reruns create 1282174+)
- ImmyBot script: 714 = `install-runner.ps1`

**Install path on machine:** `C:\ProgramData\OnboardingRunner\`
- `python/` — Python 3.12.9 embeddable package
- `runner/` — extracted from runner.zip (GitHub release v0.1.0)
  - `vendor/` — 92 pre-built wheels (fully offline, no PyPI needed)
  - `worker.py` — main service entrypoint
  - `.env` — written by install script with API keys
- `logs/install.log` — PS transcript of install run
- `logs/service.log` — NSSM service stdout/stderr

**Service:** OnboardingRunner (Windows service via NSSM)
- NSSM downloaded from nssm.cc (accessible on machine)
- Runs `python.exe worker.py` from `C:\ProgramData\OnboardingRunner\runner\`

**ImmyBot detection:** registry key `HKLM:\SOFTWARE\WraithRunner\Version`

**Central API:** Not yet deployed (planned: Railway). `WORKER_API_URL` points to future endpoint.

---

## Pending / next steps

- [ ] Confirm latest runner.zip (all-wheels, no tar.gz) fixes the ImmyBot session timeout
- [ ] Verify NSSM installs and service starts successfully
- [ ] Confirm detection script reads registry key → session passes (Status=0)
- [ ] Deploy central API to Railway
- [ ] Generate production device API keys
- [ ] Commit all local changes (install-runner.ps1, vendor/ wheels, runner.zip)
