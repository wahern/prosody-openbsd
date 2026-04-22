-- Ensure mod_unveil is loaded as early as possible, preferably before any
-- other module, but after prosody.cfg.lua has been loaded. One of our
-- primary threat vectors is modules potentially loading untrusted or
-- malformed state and code from /var/prosody, as data under /var/prosody is
-- writable at runtime. We want to minimize our capabilities as much as
-- possible before any module is loaded which may read data from
-- /var/prosody. After all modules are loaded and initializations completed,
-- we can further reduce capabilities and seal the sandbox--accomplished by
-- a server-started hook installed from mod_pledge.
--
-- NOTES:
--   * Modules are loaded in a roughly random order by iteration over a
--     util.set--a hash, not an array--from host-activated handler(s). We
--     must install our handler directly from the configuration, rather than
--     relying on the definition order of modules_enabled. See
--     https://hg.prosody.im/trunk/file/7777f25d5266/core/modulemanager.lua#l86
--     https://hg.prosody.im/trunk/file/7777f25d5266/core/modulemanager.lua#l42
--     https://hg.prosody.im/trunk/file/7777f25d5266/util/set.lua
--
--   * Handlers are invoked in descending order of priority. See
--     https://hg.prosody.im/trunk/file/469e4453ed01/util/events.lua#l39
--
Lua.prosody.events.add_handler("server-starting", function ()
	local openbsd = require"prosody.util.openbsd"
	local log = require"prosody.util.logger".init("openbsd.cfg.lua");
	local modulemanager = require"prosody.core.modulemanager"

	local mod, err = modulemanager.load("*", "ktrace")
	if not mod then
		log("error", "unable to load mod_ktrace: %s", err or "?")
	end

	-- emit after loading mod_ktrace, in case it starts a trace
	openbsd.utrace"server-starting"

	for _, modname in ipairs{
		"pledge",
		"unveil",
	} do
		local mod, err = modulemanager.load("*", modname)
		if not mod then
			log("error", "unable to load mod_%s: %s", modname, err or "?")
			-- bail on load error rather than leave process unguarded
			os.exit(1)
		end
	end
end, 99)
