"""
MCP server exposing runner tools over stdio.

Register in Claude Code settings (~/.claude/settings.json):
{
  "mcpServers": {
    "endpoint-runner": {
      "command": "python",
      "args": ["C:\\path\\to\\runner\\tools\\mcp_tools.py"]
    }
  }
}

Then call the tool from any Claude agent:
  signin_app(app="zoom", method="sso", client="Acme", user="alice@acme.com", sso_domain="acmecorp")
"""

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from fastmcp import FastMCP
from job import AuthMethod, SignInRequest
from apps.registry import get_app
from computer_use.loop import run_signin_loop

mcp = FastMCP("Endpoint Runner")


@mcp.tool()
def signin_app(
    app: str,
    method: str,
    client: str,
    user: str,
    device: str = "unknown",
    sso_domain: str | None = None,
    username: str | None = None,
    password: str | None = None,
    notes: str | None = None,
) -> dict:
    """
    Sign a user into a desktop or browser app on this endpoint using an LLM-guided
    computer-use loop. Returns a structured result with status and detail.

    method: "sso" | "user_pass" | "skip"
    """
    profile = get_app(app)
    if not profile:
        return {"status": "failed_safely", "detail": f"App '{app}' is not registered."}

    try:
        auth_method = AuthMethod(method)
    except ValueError:
        return {"status": "failed_safely", "detail": f"Unknown method '{method}'. Use sso, user_pass, or skip."}

    if auth_method not in profile.supported_methods:
        return {"status": "failed_safely", "detail": f"Method '{method}' not supported for {app}."}

    request = SignInRequest(
        client=client, device=device, user=user, app=app,
        method=auth_method,
        sso_domain=sso_domain, username=username, password=password, notes=notes,
    )

    result = run_signin_loop(profile, request)
    return {"status": result.status, "detail": result.detail, "app": result.app}


@mcp.tool()
def list_apps() -> list[dict]:
    """List all registered apps and their supported sign-in methods."""
    from apps.registry import list_apps as _list
    return _list()


if __name__ == "__main__":
    mcp.run()
