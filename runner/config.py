from dotenv import load_dotenv
import os

load_dotenv()

ANTHROPIC_API_KEY: str = os.environ["ANTHROPIC_API_KEY"]
RUNNER_MAX_STEPS: int = int(os.getenv("RUNNER_MAX_STEPS", "10"))
RUNNER_STEP_DELAY_MS: int = int(os.getenv("RUNNER_STEP_DELAY_MS", "800"))
RUNNER_SCREENSHOT_SCALE: float = float(os.getenv("RUNNER_SCREENSHOT_SCALE", "0.75"))
LOG_LEVEL: str = os.getenv("LOG_LEVEL", "INFO")
SLACK_WEBHOOK: str | None = os.getenv("SLACK_WEBHOOK")

# Central API (worker mode)
WORKER_API_URL: str = os.getenv("WORKER_API_URL", "http://localhost:8001")
WORKER_DEVICE_KEY: str = os.getenv("WORKER_DEVICE_KEY", "")
WORKER_POLL_INTERVAL: int = int(os.getenv("WORKER_POLL_INTERVAL", "5"))

# Anthropic computer-use constants — update here if Anthropic releases a new beta
CU_BETA = "computer-use-2025-01-24"
CU_TOOL_TYPE = "computer_20250124"
CU_MODEL = "claude-sonnet-4-5"
