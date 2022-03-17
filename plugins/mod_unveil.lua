-- =====================================================================
-- mod_unveil.lua - Prosody OpenBSD sandboxing module
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
local openbsd = require"util.openbsd"

module:set_global()

-- abspath :: path:string [, basedir:string] -> string
--
-- Like realpath(3) but DOES NOT resolve symlinks--easier to trace input
-- paths to configuration settings, and less likely to invite TOCTTOU races
-- with false promises of symlink resolution.
--
local function abspath(path, basedir)
	if not path:match"^/" then
		basedir = basedir or prosody.paths.config or "."
		if not basedir:match"^/" then
			basedir = assert(openbsd.getcwd()) .. "/" .. basedir
		end
		path = basedir .. "/" .. path
	end

	-- build stack of path components as-if walking filesystem tree
	local stack = {}
	for component in path:gmatch"[^/]+" do
		if component == "." then
			-- leave last component on stack
		elseif component == ".." then
			assert(#stack > 0, path)
			stack[#stack] = nil -- pop component
		else
			stack[#stack + 1] = component -- push component
		end
	end

	return "/" .. table.concat(stack, "/")
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
				return abspath(v)
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

local function xpwrap(f, msgh)
	local function finishpcall(status, ...)
		if not status then
			return false, msgh(...)
		else
			return ...
		end
	end

	return function (...)
		return finishpcall(pcall(f, ...))
	end
end

local orderedmap = {}; do
	orderedmap.__index = orderedmap

	function orderedmap.__call(self, _, previousindex)
		local list = self:getlist()
		local nextentry

		if previousindex == nil then
			nextentry = self.index[list[1]]
		else
			local previousentry = self.index[previousindex]
			local nextindex = previousentry and list[previousentry.i + 1]
			nextentry = nextindex and self.index[nextindex] or nil
		end

		if nextentry then
			return nextentry.k, nextentry.v
		end
	end

	function orderedmap:getlist()
		if self.dirty then
			local list = {}
			local n = 0

			for k in pairs(self.index) do
				n = n + 1
				list[n] = k
			end

			table.sort(list, function (a, b)
				a = self.index[a]
				b = self.index[b]

				if a.r == b.r then
					return a.n < b.n
				else
					return a.r < b.r
				end
			end)

			for i, k in ipairs(list) do
				self.index[k].i = i
			end

			self.dirty = false
			self.list = list
		end

		return self.list
	end

	function orderedmap:getcounter()
		local counter = self.counter
		self.counter = counter + 1
		return counter
	end

	function orderedmap:insert(k, v, rank)
		local entry = self.index[k]
		if not entry then
			entry = {
				k = k,
				v = v,
				r = rank or 0,
				n = self:getcounter(),
			}
			self.index[k] = entry
			self.dirty = true
		elseif entry.v ~= v then
			return nil, string.format("key %q exists with different value", k), entry.v, entry.r
		elseif entry.r ~= (rank or entry.r) then
			return nil, string.format("key %q exists with different rank", k), entry.v, entry.r
		end

		return self
	end

	local function update(self, entry, v, rank)
		entry.v = v

		local r0 = entry.r
		local r1 = rank or r0
		if r0 ~= r1 then
			self.dirty = true
		end
		entry.r = r1

		return self
	end

	function orderedmap:update(k, v, rank)
		local entry = self.index[k]
		if entry then
			return update(self, entry, v, rank)
		else
			return nil, string.format("key %q does not exist", k)
		end
	end

	function orderedmap:upsert(k, v, rank)
		local entry = self.index[k]
		if entry then
			return update(self, entry, v, rank)
		else
			return self:insert(k, v, rank)
		end
	end

	function orderedmap:delete(k)
		self.index[k] = nil
		self.dirty = true

		return self
	end

	function orderedmap:exists(k)
		local entry = self.index[k]
		if entry then
			return true, entry.v, entry.r
		else
			return false
		end
	end

	function orderedmap.new()
		local self = {
			counter = 1,
			dirty = false,
			index = {},
			list = {},
		}
		return setmetatable(self, orderedmap)
	end
end

local pathlist = {}; do
	pathlist.__index = pathlist

	function pathlist.__call(self, _, previousindex)
		return self.inner(_, previousindex)
	end

	local function selfresult(self, r, ...)
		if r then return self, ... else return r, ... end
	end

	function pathlist:add(path, permissions)
		path = abspath(path)
		permissions = permissions or "r"

		return selfresult(self, self.inner:upsert(path, permissions))
	end

	function pathlist:delete(path)
		return selfresult(self, self.inner:delete(abspath(path)))
	end

	function pathlist:addline(l)
		local permissions, path = l:match"^[ \t]*([-rwxc]+)[ \t]+(.+)$"
		if permissions and path then
			if permissions == "-" then
				return self:delete(path)
			else
				return self:add(path, permissions)
			end
		end

		return nil, string.format("malformed unveil line directive %q", l)
	end

	function pathlist:addlines(s)
		for l in s:gmatch"[^\n]+" do
			if l:match"[^%s]" then
				local ok, err = self:addline(l)
				if not ok then
					return nil, err
				end
			end
		end

		return self
	end

	function pathlist:additem(item)
		local err

		if type(item) == "string" then
			return self:addlines(item)
		elseif type(item) == "table" then
			local path = item.path or item[1]
			local permissions = item.permissions or item[2]

			if type(path) == "string" then
				return self:add(path, permissions)
			end

			err = string.format("unveil item missing path")
		else
			err = string.format("bad unveil item type (string or table expected, got %s)", type(item))
		end

		return nil, err or "?"
	end

	function pathlist:additems(t)
		for _, item in ipairs(t) do
			local ok, err = self:additem(item)

			if not ok then
				return nil, err or "?"
			end
		end

		return self
	end

	function pathlist.new()
		local self = {
			inner = orderedmap.new(),
		}
		return setmetatable(self, pathlist)
	end
end

local promiselist = {}; do
	promiselist.__index = promiselist

	function promiselist.__call(self, _, previousindex)
		return self.inner(_, previousindex)
	end

	local function selfresult(self, r, ...)
		if r then return self, ... else return r, ... end
	end

	function promiselist:add1(promise)
		return selfresult(self, self.inner:insert(promise))
	end

	function promiselist:delete1(promise)
		return selfresult(self, self.inner:delete(promise))
	end

	function promiselist:add(s)
		for promise in s:gmatch"[^%s]+" do
			local ok, err

			if promise:match"^-." then
				ok, err = self:delete1(promise:sub(2))
			else
				ok, err = self:add1(promise)
			end
			if not ok then
				return nil, err or "?"
			end
		end

		return self
	end

	function promiselist.new()
		local self = {
			inner = orderedmap.new(),
		}
		return setmetatable(self, promiselist)
	end
end

local _UNVEIL_INIT = {
	{ path = assert(prosody.paths.config), permissions = "r" },
	{ path = assert(prosody.paths.source), permissions = "r" },
	{ path = assert(prosody.paths.data), permissions = "rwc" },
	{ path = "/etc/ssl/cert.pem", permissions = "r" },
}

-- The flock and proc pledges are required initially for mod_posix
-- daemonization (presuming we're loaded early enough), then we can drop.
-- NB: Unlike unveil, subsequent pledges cannot expand capabilities.
local _PROMISES_SEAL = "stdio rpath wpath cpath inet dns"
local _PROMISES_INIT = _PROMISES_SEAL .. " flock proc prot_exec"

local unveil_enabled = module:get_option("unveil", true)
local pledge_enabled = module:get_option("pledge", true)

local function init_unveil()
	local paths = assert(pathlist.new():additems(_UNVEIL_INIT))

	for path in ssl_paths() do
		assert(paths:add(path, "r"))
	end

	local unveil_type = type(unveil_enabled)
	if unveil_type == "string" then
		assert(paths:addlines(unveil_enabled))
	elseif unveil_type == "table" then
		assert(paths:additems(unveil_enabled))
	elseif unveil_type ~= "boolean" then
		error(string.format("bad unveil_enabled type (string or table expected, got %s)", unveil_type))
	end

	for path, permissions in paths do
		module:log("info", "unveiling %s (%s)", path, permissions)
		assert(openbsd.unveil(path, permissions))
	end

	-- Seal paths early as one of our main concerns is modules
	-- potentially loading untrusted code, e.g. from /var/prosody.
	assert(openbsd.unveil())
	module:log("info", "unveil sealed")
end

local function init_pledge()
	local promises = promiselist.new()

	promises:add(_PROMISES_INIT)

	if type(pledge_enabled) == "string" then
		promises:add(pledge_enabled)
	end

	local s = table.concat(promises.inner:getlist(), " ")
	module:log("info", "pledging %s", s)
	assert(openbsd.pledge(s))
end

local function seal_pledge()
	local promises = promiselist.new()

	promises:add(_PROMISES_SEAL)

	if type(pledge_enabled) == "string" then
		promises:add(pledge_enabled)
	end

	local s = table.concat(promises.inner:getlist(), " ")
	module:log("info", "pledging %s", s)
	assert(openbsd.pledge(s))

	assert(openbsd.pledge())
	module:log("info", "pledge sealed")
end

local function on_error(err)
	module:log("error", "%s", tostring(err))

	-- bail on load error rather than leave process unguarded
	os.exit(1)
end

local init_sandbox = xpwrap(function ()
	if unveil_enabled then
		init_unveil()
	end

	if pledge_enabled then
		init_pledge()
	end
end, on_error)

local seal_sandbox = xpwrap(function()
	if pledge_enabled then
		seal_pledge()
	end
end, on_error)

init_sandbox()
module:hook_global("server-started", seal_sandbox, -99)
