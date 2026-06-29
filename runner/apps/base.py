from dataclasses import dataclass, field
from job import AuthMethod


@dataclass
class AppProfile:
    name: str
    app_type: str  # "desktop" | "browser" | "hybrid"
    supported_methods: list[AuthMethod]
    executable_hints: list[str]
    launch_command: str | None
    sso_instructions: str
    user_pass_instructions: str
    skip_instructions: str
    success_criteria: list[str]
    stop_conditions: list[str]
    post_signin_verification: str | None = None
