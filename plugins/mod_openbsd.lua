-- =====================================================================
-- mod_openbsd.lua - Prosody OpenBSD sandboxing module
-- ---------------------------------------------------------------------
-- Copyright (c) 2022 William Ahern
--
-- Permission is hereby granted, free of charge, to any person obtaining
-- a copy of this software and associated documentation files (the
-- "Software"), to deal in the Software without restriction, including
-- without limitation the rights to use, copy, modify, merge, publish,
-- distribute, sublicense, and/or sell copies of the Software, and to
-- permit persons to whom the Software is furnished to do so, subject to
-- the following conditions:
--
-- The above copyright notice and this permission notice shall be
-- included in all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
-- EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
-- MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
-- IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
-- CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
-- TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
-- SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
-- ======================================================================
local configmanager = require"core.configmanager"
local pathutil = require"util.paths"
local openbsd = require"util.openbsd"

local function resolve_path(path, dir)
	dir = dir or prosody.paths.config or "."
	return pathutil.resolve_relative_path(dir, path)
end

-- Enumerate enabled hosts. See core/hostmanager.lua:load_enabled_hosts and
-- util/prosodyctl/check.lua:enabled_hosts.
local function enabled_hosts()
	return coroutine.wrap(function ()
		for host, cfg in pairs(configmanager.getconfig()) do
			if host ~= "*" and cfg.enabled ~= false then
				coroutine.yield(host)
			end
		end
	end)
end

-- Search configuration for SSL key and certificate paths.
-- See plugins/mod_tls.lua:module.load.
local function ssl_paths()
	return coroutine.wrap(function ()
		local seen = {}

		local function to_path(v)
			if type(v) ~= "string" then
				return false
			else
				return resolve_path(v)
			end
		end

		local function post_path(v)
			local path = to_path(v)
			if not path then return end

			if seen[path] then return end
			seen[path] = true

			coroutine.yield(path)
		end

		for host in enabled_hosts() do
			for _, opt in ipairs{ "ssl", "c2s_ssl", "s2s_ssl" } do
				local cfg = configmanager.get(host, opt) or {}
				for field in string.gmatch("key certificate cafile capath", "%w+") do
					post_path(cfg[field])
				end
			end
		end
	end)
end

module:set_global()

module:hook_global("server-started", function ()
	local paths = {
		{ assert(CFG_CONFIGDIR), "r" },
		{ assert(CFG_SOURCEDIR), "r" },
		{ assert(CFG_DATADIR), "rwc" },
		{ "/etc/ssl/cert.pem", "r" },
	}

	for path in ssl_paths() do
		paths[#paths + 1] = { path, "r" }
	end

	for _, p in ipairs(paths) do
		local path = assert(p[1], "no path specified")
		local perms = assert(p[2], "no permissions specified for " .. path)
		module:log("info", "unveiling %s (%s)", path, perms)
		assert(openbsd.unveil(path, perms))
	end
	assert(openbsd.unveil()) -- finalize paths

	local promises = "stdio rpath wpath cpath inet dns"
	module:log("info", "pledging %s", promises)
	assert(openbsd.pledge(promises))
	assert(openbsd.pledge()) -- finalize pledges
end)
