from enum import Enum
from pydantic import BaseModel, Field


class AuthMethod(str, Enum):
    sso = "sso"
    user_pass = "user_pass"
    skip = "skip"


class SignInRequest(BaseModel):
    client: str
    device: str
    user: str
    app: str
    method: AuthMethod
    sso_domain: str | None = None
    username: str | None = None
    password: str | None = Field(default=None, repr=False, exclude=True)
    notes: str | None = None
    slack_webhook: str | None = Field(default=None, repr=False, exclude=True)


class SignInResult(BaseModel):
    app: str
    method: AuthMethod
    status: str
    detail: str | None = None
    screenshot_b64: str | None = Field(default=None, repr=False)
