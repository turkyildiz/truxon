import enum


class UserRole(str, enum.Enum):
    ADMIN = "admin"
    DISPATCHER = "dispatcher"
    DRIVER = "driver"
    ACCOUNTANT = "accountant"
    MAINTENANCE = "maintenance"


class DriverStatus(str, enum.Enum):
    ACTIVE = "active"
    INACTIVE = "inactive"
    TERMINATED = "terminated"


class EquipmentStatus(str, enum.Enum):
    AVAILABLE = "available"
    IN_USE = "in_use"
    MAINTENANCE = "maintenance"
    RETIRED = "retired"


class EquipmentType(str, enum.Enum):
    TRUCK = "truck"
    TRAILER = "trailer"


class LoadStatus(str, enum.Enum):
    PENDING = "pending"
    ASSIGNED = "assigned"
    IN_TRANSIT = "in_transit"
    DELIVERED = "delivered"
    COMPLETED = "completed"
    BILLED = "billed"


# Allowed forward transitions of the load lifecycle. Any status can also
# move one step back (correction) — enforced in the API layer.
LOAD_STATUS_ORDER = [
    LoadStatus.PENDING,
    LoadStatus.ASSIGNED,
    LoadStatus.IN_TRANSIT,
    LoadStatus.DELIVERED,
    LoadStatus.COMPLETED,
    LoadStatus.BILLED,
]


class InvoiceStatus(str, enum.Enum):
    DRAFT = "draft"
    SENT = "sent"
    PAID = "paid"
