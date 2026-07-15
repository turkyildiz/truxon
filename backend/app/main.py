import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.api import auth, customers, dispatch, documents, drivers, invoices, loads, maintenance, reports
from app.api.equipment import trailers_router, trucks_router
from app.core.config import get_settings
from app.core.security import hash_password
from app.db import Base, SessionLocal, engine
from app.models import User, UserRole

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)
settings = get_settings()


def seed_initial_admin() -> None:
    """Create the first admin account if the users table is empty."""
    with SessionLocal() as db:
        if db.query(User).count() == 0:
            db.add(
                User(
                    username=settings.initial_admin_username,
                    full_name="Administrator",
                    password_hash=hash_password(settings.initial_admin_password),
                    role=UserRole.ADMIN,
                )
            )
            db.commit()
            logger.warning(
                "Created initial admin user %r — change its password immediately.",
                settings.initial_admin_username,
            )


@asynccontextmanager
async def lifespan(app: FastAPI):
    # In production, schema is managed by Alembic (run migrations in the container
    # entrypoint). create_all is a no-op for tables that already exist.
    Base.metadata.create_all(bind=engine)
    settings.upload_dir.mkdir(parents=True, exist_ok=True)
    seed_initial_admin()
    yield


app = FastAPI(title=settings.app_name, lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth.router)
app.include_router(auth.users_router)
app.include_router(customers.router)
app.include_router(drivers.router)
app.include_router(trucks_router)
app.include_router(trailers_router)
app.include_router(maintenance.router)
app.include_router(loads.router)
app.include_router(documents.router)
app.include_router(dispatch.router)
app.include_router(invoices.router)
app.include_router(reports.router)


@app.get("/api/health")
def health():
    return {"status": "ok"}
