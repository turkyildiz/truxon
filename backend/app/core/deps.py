"""FastAPI dependencies: current user resolution and role-based access control."""

import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from sqlalchemy.orm import Session

from app.core.security import decode_access_token
from app.db import get_db
from app.models import User, UserRole

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/api/auth/login")


def get_current_user(token: str = Depends(oauth2_scheme), db: Session = Depends(get_db)) -> User:
    credentials_error = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Could not validate credentials",
        headers={"WWW-Authenticate": "Bearer"},
    )
    try:
        payload = decode_access_token(token)
    except jwt.PyJWTError:
        raise credentials_error
    user = db.query(User).filter(User.username == payload.get("sub")).first()
    if user is None or not user.is_active:
        raise credentials_error
    return user


def require_roles(*roles: UserRole):
    """Admin always passes; other roles must be in the allowed list."""

    def checker(user: User = Depends(get_current_user)) -> User:
        if user.role == UserRole.ADMIN or user.role in roles:
            return user
        raise HTTPException(status_code=403, detail="Not enough permissions")

    return checker


# Module-level access per the spec's RBAC matrix (admin implicitly everywhere).
OperationsAccess = Depends(require_roles(UserRole.DISPATCHER))
FleetReadAccess = Depends(require_roles(UserRole.DISPATCHER, UserRole.ACCOUNTANT, UserRole.MAINTENANCE))
AccountingAccess = Depends(require_roles(UserRole.ACCOUNTANT))
MaintenanceAccess = Depends(require_roles(UserRole.MAINTENANCE))
AdminOnly = Depends(require_roles())
