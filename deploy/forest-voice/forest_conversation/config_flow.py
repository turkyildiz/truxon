"""Config flow for Forest (Truxon)."""

import voluptuous as vol

from homeassistant import config_entries

from .const import CONF_ANON_KEY, CONF_EMAIL, CONF_PASSWORD, CONF_URL, DOMAIN

SCHEMA = vol.Schema(
    {
        vol.Required(CONF_URL): str,
        vol.Required(CONF_ANON_KEY): str,
        vol.Required(CONF_EMAIL): str,
        vol.Required(CONF_PASSWORD): str,
    }
)


class ForestConfigFlow(config_entries.ConfigFlow, domain=DOMAIN):
    VERSION = 1

    async def async_step_user(self, user_input=None):
        if user_input is not None:
            await self.async_set_unique_id(DOMAIN)
            self._abort_if_unique_id_configured()
            return self.async_create_entry(title="Forest", data=user_input)
        return self.async_show_form(step_id="user", data_schema=SCHEMA)
