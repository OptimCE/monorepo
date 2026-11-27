"""Who is asking, resolved from crm_db without any HTTP request.

An export message carries only Keycloak ids. A handler needs what the API's gateway headers
would have given it: the requester's CRM user, their linked members and, for a community
export, the community and their role in it. This module reads them from crm_db with the same
tables every annexe already reads (app_user, user_member_link, community, community_user), so a
worker-free, FastAPI-free handler can apply the service's own permission functions.

Setting the service's ContextVars from a Requester is the service's job (their names differ
per annexe); this module stays framework-free.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Protocol

from .errors import ExportPartError


@dataclass(frozen=True)
class Requester:
    auth_user_id: str
    # None when the user never reached the CRM (no app_user row): they have no data anywhere.
    user_id: int | None
    # Members linked to the user (user_member_link), every community included.
    member_ids: tuple[int, ...] = field(default_factory=tuple)
    # Community export only.
    community_id: int | None = None
    auth_community_id: str | None = None
    role: str | None = None


class CrmLookup(Protocol):
    async def user_id(self, auth_user_id: str) -> int | None: ...

    async def member_ids(self, user_id: int) -> tuple[int, ...]: ...

    async def community_id(self, auth_community_id: str) -> int | None: ...

    async def role(self, user_id: int, community_id: int) -> str | None: ...


class SqlCrmLookup:
    """CrmLookup over a SQLAlchemy AsyncSession bound to crm_db."""

    def __init__(self, session: Any) -> None:
        self._session = session

    async def _scalar(self, sql: str, params: dict[str, Any]) -> Any:
        from sqlalchemy import text

        result = await self._session.execute(text(sql), params)
        return result.scalar_one_or_none()

    async def user_id(self, auth_user_id: str) -> int | None:
        value = await self._scalar(
            "SELECT id FROM app_user WHERE auth_user_id = :sub", {"sub": auth_user_id}
        )
        return int(value) if value is not None else None

    async def member_ids(self, user_id: int) -> tuple[int, ...]:
        from sqlalchemy import text

        result = await self._session.execute(
            text(
                "SELECT DISTINCT id_member FROM user_member_link WHERE id_user = :u "
                "ORDER BY id_member"
            ),
            {"u": user_id},
        )
        return tuple(int(row[0]) for row in result)

    async def community_id(self, auth_community_id: str) -> int | None:
        value = await self._scalar(
            "SELECT id FROM community WHERE auth_community_id = :c",
            {"c": auth_community_id},
        )
        return int(value) if value is not None else None

    async def role(self, user_id: int, community_id: int) -> str | None:
        value = await self._scalar(
            "SELECT role FROM community_user WHERE id_user = :u AND id_community = :c",
            {"u": user_id, "c": community_id},
        )
        return str(value) if value is not None else None


async def resolve_requester(lookup: CrmLookup, request: dict[str, Any]) -> Requester:
    """Resolves the requester of ``request``, re-checking their rights at processing time.

    - user scope: the export is always the requester's own (scope.id == requester.userId);
    - community scope: the community must exist and the requester must still be its ADMIN.

    Raises ExportPartError (``forbidden`` / ``scope_not_found``) otherwise.
    """
    sub = str(request["requester"]["userId"])
    scope_type = request["scope"]["type"]
    scope_id = str(request["scope"]["id"])
    user_id = await lookup.user_id(sub)

    if scope_type == "user":
        if scope_id != sub:
            raise ExportPartError("forbidden", "a user export is only ever the requester's own")
        members = await lookup.member_ids(user_id) if user_id is not None else ()
        return Requester(auth_user_id=sub, user_id=user_id, member_ids=members)

    community_id = await lookup.community_id(scope_id)
    if community_id is None:
        raise ExportPartError("scope_not_found", "community unknown to this service")
    role = await lookup.role(user_id, community_id) if user_id is not None else None
    if role != "ADMIN":
        raise ExportPartError("forbidden", "requester is not ADMIN of the community")
    members = await lookup.member_ids(user_id) if user_id is not None else ()
    return Requester(
        auth_user_id=sub,
        user_id=user_id,
        member_ids=members,
        community_id=community_id,
        auth_community_id=scope_id,
        role=role,
    )
