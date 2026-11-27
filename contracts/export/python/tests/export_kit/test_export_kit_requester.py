"""resolve_requester's rules, on an in-memory CRM (copied with core/export).

The SQL of SqlCrmLookup is exercised by each service against its own crm_test_schema.sql.
"""

from __future__ import annotations

import pytest

from core.export import ExportPartError, resolve_requester


class FakeCrm:
    def __init__(self) -> None:
        self.users = {"auth0|admin": 2, "auth0|member": 4, "auth0|manager": 3}
        self.links = {4: (7, 9), 2: ()}
        self.communities = {"2c8a": 1}
        self.roles = {(2, 1): "ADMIN", (3, 1): "MANAGER", (4, 1): "MEMBER"}

    async def user_id(self, auth_user_id: str) -> int | None:
        return self.users.get(auth_user_id)

    async def member_ids(self, user_id: int) -> tuple[int, ...]:
        return self.links.get(user_id, ())

    async def community_id(self, auth_community_id: str) -> int | None:
        return self.communities.get(auth_community_id)

    async def role(self, user_id: int, community_id: int) -> str | None:
        return self.roles.get((user_id, community_id))


def request(scope_type: str, scope_id: str, requester: str) -> dict:
    return {
        "scope": {"type": scope_type, "id": scope_id},
        "requester": {"userId": requester},
    }


async def test_a_user_export_resolves_the_linked_members() -> None:
    requester = await resolve_requester(FakeCrm(), request("user", "auth0|member", "auth0|member"))
    assert (requester.user_id, requester.member_ids) == (4, (7, 9))
    assert requester.community_id is None


async def test_a_user_unknown_to_the_crm_has_no_members_and_no_error() -> None:
    requester = await resolve_requester(FakeCrm(), request("user", "auth0|new", "auth0|new"))
    assert (requester.user_id, requester.member_ids) == (None, ())


async def test_a_user_export_of_someone_else_is_forbidden() -> None:
    with pytest.raises(ExportPartError) as err:
        await resolve_requester(FakeCrm(), request("user", "auth0|member", "auth0|admin"))
    assert err.value.code == "forbidden"


async def test_a_community_export_needs_the_requester_to_still_be_admin() -> None:
    requester = await resolve_requester(FakeCrm(), request("community", "2c8a", "auth0|admin"))
    assert (requester.community_id, requester.role) == (1, "ADMIN")
    for sub in ("auth0|manager", "auth0|member", "auth0|stranger"):
        with pytest.raises(ExportPartError) as err:
            await resolve_requester(FakeCrm(), request("community", "2c8a", sub))
        assert err.value.code == "forbidden"


async def test_an_unknown_community_is_scope_not_found() -> None:
    with pytest.raises(ExportPartError) as err:
        await resolve_requester(FakeCrm(), request("community", "nope", "auth0|admin"))
    assert err.value.code == "scope_not_found"
