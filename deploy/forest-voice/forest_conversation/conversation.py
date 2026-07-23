"""Forest conversation entity: HA Assist -> Supabase trux-agent."""

import logging
import re
import time

import aiohttp

from homeassistant.components import conversation
from homeassistant.config_entries import ConfigEntry
from homeassistant.core import HomeAssistant
from homeassistant.helpers import intent
from homeassistant.helpers.aiohttp_client import async_get_clientsession
from homeassistant.helpers.entity_platform import AddEntitiesCallback

from .const import CONF_ANON_KEY, CONF_EMAIL, CONF_PASSWORD, CONF_URL

_LOGGER = logging.getLogger(__name__)

# GoTrue access tokens live 1h; refresh with 10 min to spare.
TOKEN_TTL = 50 * 60
AGENT_TIMEOUT = aiohttp.ClientTimeout(total=120)


def _speakable(text: str) -> str:
    """The reply is fed to TTS: markdown survives the agent's radio note sometimes."""
    text = re.sub(r"[*_#`]+", "", text)
    text = re.sub(r"^\s*[-•]\s+", "", text, flags=re.M)
    return re.sub(r"\s*\n+\s*", " ", text).strip()


async def async_setup_entry(
    hass: HomeAssistant, entry: ConfigEntry, async_add_entities: AddEntitiesCallback
) -> None:
    async_add_entities([ForestAgent(hass, entry)])


class ForestAgent(conversation.ConversationEntity):
    _attr_name = "Forest"
    _attr_unique_id = "forest_truxon_agent"

    def __init__(self, hass: HomeAssistant, entry: ConfigEntry) -> None:
        self.hass = hass
        self._url = entry.data[CONF_URL].rstrip("/")
        self._anon = entry.data[CONF_ANON_KEY]
        self._email = entry.data[CONF_EMAIL]
        self._password = entry.data[CONF_PASSWORD]
        self._jwt: str | None = None
        self._jwt_at = 0.0
        # HA conversation_id -> trux session_id, so follow-ups share context
        self._sessions: dict[str, str] = {}

    @property
    def supported_languages(self) -> list[str]:
        return ["en"]

    async def _token(self) -> str:
        if self._jwt and time.monotonic() - self._jwt_at < TOKEN_TTL:
            return self._jwt
        session = async_get_clientsession(self.hass)
        async with session.post(
            f"{self._url}/auth/v1/token?grant_type=password",
            json={"email": self._email, "password": self._password},
            headers={"apikey": self._anon},
            timeout=aiohttp.ClientTimeout(total=20),
        ) as resp:
            body = await resp.json()
            if resp.status != 200:
                raise RuntimeError(f"Forest sign-in failed: {body.get('error_description') or body}")
        self._jwt = body["access_token"]
        self._jwt_at = time.monotonic()
        return self._jwt

    async def async_process(
        self, user_input: conversation.ConversationInput
    ) -> conversation.ConversationResult:
        conversation_id = user_input.conversation_id or "default"
        response = intent.IntentResponse(language=user_input.language)
        try:
            jwt = await self._token()
            session = async_get_clientsession(self.hass)
            payload: dict = {"message": user_input.text, "radio": True}
            if conversation_id in self._sessions:
                payload["session_id"] = self._sessions[conversation_id]
            async with session.post(
                f"{self._url}/functions/v1/trux-agent",
                json=payload,
                headers={"apikey": self._anon, "Authorization": f"Bearer {jwt}"},
                timeout=AGENT_TIMEOUT,
            ) as resp:
                body = await resp.json()
            if resp.status != 200:
                raise RuntimeError(body.get("error") or f"trux-agent HTTP {resp.status}")
            if body.get("session_id"):
                self._sessions[conversation_id] = body["session_id"]
            reply = _speakable(body.get("reply") or "") or "I didn't get an answer back."
            if body.get("proposals"):
                reply += " I prepared an action that needs your confirmation in the Truxon app."
            response.async_set_speech(reply)
        except Exception as err:  # noqa: BLE001 — any failure must become speech, not a stack trace
            _LOGGER.exception("Forest agent error")
            self._jwt = None  # force re-auth next turn
            response.async_set_error(
                intent.IntentResponseErrorCode.UNKNOWN,
                f"I hit a problem talking to Forest: {err}",
            )
        return conversation.ConversationResult(
            response=response, conversation_id=conversation_id
        )
