from apps.base import AppProfile
from apps.zoom import zoom_profile

_REGISTRY: dict[str, AppProfile] = {
    "zoom": zoom_profile,
}


def get_app(name: str) -> AppProfile | None:
    return _REGISTRY.get(name.lower())


def list_apps() -> list[dict]:
    return [
        {"app": name, "supported_methods": [m.value for m in profile.supported_methods]}
        for name, profile in _REGISTRY.items()
    ]
