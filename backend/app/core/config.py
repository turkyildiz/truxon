from functools import lru_cache
from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Application settings, loaded from environment variables / .env file."""

    model_config = SettingsConfigDict(env_file=".env", env_prefix="TRUCKSON_", extra="ignore")

    app_name: str = "TrucksOn TMS"
    environment: str = "development"  # development | production

    # SQLite fallback keeps local development dependency-free;
    # docker-compose overrides this with the PostgreSQL URL.
    database_url: str = "sqlite:///./truckson_dev.db"

    secret_key: str = "dev-only-secret-change-me-in-production-0000"
    access_token_expire_minutes: int = 720  # 12h session
    algorithm: str = "HS256"

    # Where uploaded documents (BOLs, PODs, licenses, receipts) are stored.
    upload_dir: Path = Path("./uploads")

    # Optional integrations — features degrade gracefully when unset.
    google_maps_api_key: str = ""
    llm_api_key: str = ""  # OpenRouter / Groq compatible
    llm_base_url: str = "https://openrouter.ai/api/v1"
    llm_model: str = "meta-llama/llama-3.1-8b-instruct"

    cors_origins: list[str] = ["http://localhost:5173", "http://localhost:8080"]

    # Initial admin account, created on first startup if no users exist.
    initial_admin_username: str = "admin"
    initial_admin_password: str = "admin"


@lru_cache
def get_settings() -> Settings:
    return Settings()
