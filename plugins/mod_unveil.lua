-- =====================================================================
-- mod_unveil.lua - Prosody OpenBSD sandboxing module
-- ---------------------------------------------------------------------
-- Copyright (c) 2022, 2026 William Ahern
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
local configmanager = require"prosody.core.configmanager"
local openbsd = require"prosody.util.openbsd"
local sformat = string.format

module:set_global()
-- Ensure ktrace is loaded, if at all, before us in case it needs to create
-- a trace file at a path which won't be unveil'd.
module:depends("ktrace", true)

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

-- TODO: remove if not yet used
local function chopname(path)
	local i, j = path:match"()/[^/]*()$"
	if not i then
		return nil
	elseif i > 1 then
		return path:sub(1, j - 1)
	end

	local len = j - i - 1
	if len > 0 then
		return "/"
	else
		return nil
	end
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

-- Map with insertion-order iterator.
--
-- TODO: Duplicated in mod_pledge. Put into separate util module?
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
			return nil, sformat("key %q exists with different value", k), entry.v, entry.r
		elseif entry.r ~= (rank or entry.r) then
			return nil, sformat("key %q exists with different rank", k), entry.v, entry.r
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
			return nil, sformat("key %q does not exist", k)
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

	function pathlist:wpaths()
		return coroutine.wrap(function ()
			for path, permissions in self do
				if permissions:match"w" then
					coroutine.yield(path, permissions)
				end
			end
		end)
	end

	function pathlist:add(path, permissions)
		path = abspath(path)
		permissions = permissions or "r"

		return selfresult(self, self.inner:upsert(path, permissions))
	end

	local function tpaths(template)
		return coroutine.wrap(function ()
			for rpath in template:gmatch"[^;]+" do
				local path = abspath(rpath)
				-- find directory with substitution component, if any
				local subst = path:match"()/[^/]*%?"
				if subst then
					path = path:sub(1, subst - 1)
					if #path > 0 then
						coroutine.yield(path)
					else
						module:log("warn", "skipping %s (path empty after dropping substitution suffix)", rpath)
					end
				else
					coroutine.yield(path)
				end
			end
		end)
	end

	function pathlist:addtemplate(template, permissions)
		local lasterr = nil
		for path in tpaths(template) do
			local ok, err = self:add(path, permissions)
			if not ok then
				lasterr = err
			end
		end

		return not lasterr, lasterr
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

		return nil, sformat("malformed unveil line directive %q", l)
	end

	function pathlist:addlines(s)
		local lasterr = nil

		for l in s:gmatch"[^\n]+" do
			if l:match"[^%s]" then
				local ok, err = self:addline(l)
				if not ok then
					lasterr = err or "?"
				end
			end
		end

		return (not lasterr and self), lasterr
	end

	function pathlist:additem(item)
		local err

		if type(item) == "string" then
			module:log("warn", "DEPRECATED unveil item type (table expected, got string)")
			return self:addlines(item)
		elseif type(item) == "table" then
			local path = item.template or item.path or item[1]
			local permissions = item.permissions or item[2]

			if path and path == item[1] then
				module:log("warn", "DEPRECATED path field (.path definition expected, got index 1)")
			end
			if permissions and permissions == item[2] then
				module:log("warn", "DEPRECATED permissions field (.permissions definition expected, got index 2)")
			end

			if type(path) == "string" then
				if item.template then
					return self:addtemplate(path, permissions)
				else
					return self:add(path, permissions)
				end
			end

			err = sformat("unveil item missing path")
		else
			err = sformat("bad unveil item type (table expected, got %s)", type(item))
		end

		return nil, err or "?"
	end

	function pathlist:additems(t)
		local lasterr = nil

		for _, item in ipairs(t) do
			local ok, err = self:additem(item)
			if not ok then
				lasterr = err or "?"
			end
		end

		return (not lasterr and self), lasterr
	end

	function pathlist.new()
		local self = {
			inner = orderedmap.new(),
		}
		return setmetatable(self, pathlist)
	end
end

local function check_install(paths)
	-- all paths should have already been canonicalized with abspath
	local function issubdir(dir, path)
		if #path > #dir and dir == path:sub(1, #dir) and path:match("^/", #dir + 1) then
			return true
		else
			return false
		end
	end

	local statcache = {}
	local function stat(path)
		local ent = statcache[path]
		if not ent then
			ent = {}
			ent.st, ent.err = openbsd.stat(path)
			statcache[path] = ent
		end
		return ent.st, ent.err
	end

	local function isdir(path)
		local st, err = stat(path)
		if not st then return nil, err end
		return openbsd.S_IFDIR == (st.st_mode & openbsd.S_IFMT)
	end

	local function ismine(path)
		local st, err = stat(path)
		if not st then return nil, err end

		local uid = openbsd.getuid()
		local euid = openbsd.geteuid()
		return st.st_uid == uid or st.st_uid == euid
	end

	local function iswritable(path)
		if ismine(path) then
			return true
		end

		local st, err = stat(path)
		if not st then return nil, err end

		if openbsd.S_IWOTH == (st.st_mode & openbsd.S_IWOTH) then
			return true
		end

		if openbsd.S_IWGRP == (st.st_mode & openbsd.S_IWGRP) then
			local groups, err = openbsd.getgroups()
			if not groups then return nil, err end

			groups[#groups + 1] = openbsd.getgid()
			groups[#groups + 1] = openbsd.getegid()

			for _, gid in ipairs(groups) do
				if st.st_gid == gid then
					return true
				end
			end
		end

		return false
	end

	local function issticky(path)
		local st, err = stat(path)
		if not st then return nil, err end
		return openbsd.S_ISVTX == (st.st_mode & openbsd.S_ISVTX)
	end

	local function exists(path)
		local st, err = stat(path)
		if not st then return nil, err end
		return true
	end

	for wpath in paths:wpaths() do
		local st, err = openbsd.stat(wpath)
		if not st then
			module:log("error", "unable to stat directory %s: %s", wpath, err or "?")
		end

		for path, permissions in paths do
			if issubdir(wpath, path) and not permissions:match"w" then
				if not isdir(wpath) then
					module:log("info", "%s missing parent directory (expected directory at %s)", path, wpath)
				elseif iswritable(wpath) then
					if ismine(wpath) then
						module:log("warn", "%s has unsafe parent directory (%s is owned by prosody process, recommend changing owner)", path, wpath)
					end

					if not issticky(wpath) then
						module:log("warn", "%s has unsafe parent directory (%s is writable, recommend setting sticky bit)", path, wpath)
					end

					-- find immediate child of wpath and test for existence
					local slash = path:match("()/", #wpath + 2)
					local cpath = slash and path:sub(1, slash) or path
					if not exists(cpath) then
						module:log("warn", "%s has unsafe parent directory (%s is writable, recommend creating %s)", path, wpath, cpath)
					end
				end
			end
		end
	end
end

-- returns true if we can invoke unveil(2) without killing the process
local function can_unveil()
	local modulemanager = require"prosody.core.modulemanager"
	local mod_pledge = modulemanager.get_module("*", "pledge")
	if not mod_pledge or not mod_pledge.is_pledged() then
		return true
	elseif mod_pledge.is_pledged"unveil" or mod_pledge.is_pledged"error" then
		return true
	else
		return false
	end
end

local _UNVEIL_INIT = {
	-- pre-7.9 stdio promise
	{ path = "/etc/localtime", permissions = "r" },
	{ path = "/usr/share/zoneinfo", permissions = "r" },
	-- pre-7.9 dns pledge
	{ path = "/etc/hosts", permissions = "r" },
	{ path = "/etc/resolv.conf", permissions = "r" },
	{ path = "/etc/services", permissions = "r" },
	{ path = "/etc/protocols", permissions = "r" },

	{ path = assert(prosody.paths.config), permissions = "r" },
	{ path = assert(prosody.paths.source), permissions = "r" },
	{ path = assert(prosody.paths.installer), permissions = "r" },
	{ template = assert(prosody.paths.plugins), permissions = "r" },
	{ path = assert(prosody.paths.data), permissions = "rwc" },
	{ path = "/etc/ssl/cert.pem", permissions = "r" },
}

local _STATE = {
	loaded = false,
	unveiled = nil,
}

local function parsecfg(v)
	local cfg = {
		enabled = v ~= false,
		paths = pathlist.new(),
		exitonerror = true,
		warnings = true,
	}
	local ok, err, lasterr

	ok, err = cfg.paths:additems(_UNVEIL_INIT)
	if not ok then lasterr = err or "?" end

	for path in ssl_paths() do
		ok, err = cfg.paths:add(path, "r")
		if not ok then lasterr = err or "?" end
	end

	local what = type(v)
	if what == "string" then
		module:log("warn", "DEPRECATED unveil configuration type (table expected, got string)")
		ok, err = cfg.paths:addlines(v)
		if not ok then lasterr = err or "?" end
	elseif what == "table" then
		if v.enabled ~= nil then
			cfg.enabled = not not v.enabled
		end

		if v.exitonerror ~= nil then
			cfg.exitonerror = not not v.exitonerror
		end

		if v.warnings ~= nil then
			cfg.warnings = not not v.warnings
		end

		ok, err = cfg.paths:additems(v)
		if not ok then lasterr = err or "?" end
	elseif what ~= "boolean" then
		module:log("warn", "bad unveil configuration type (table expected, got %s)", what)
	end

	-- eat error if we're not enabled anyhow
	if lasterr and not cfg.enabled then
		module:log("error", "%s", lasterr or "unveil-config-error")
		lasterr = nil
	end

	return cfg, lasterr
end

local _CFG = nil
local _ERR = nil
local function getcfg(noerror)
	if not _CFG then
		_CFG, _ERR = parsecfg(module:get_option("unveil", true))
	end

	if _ERR and not noerror then
		return nil, _ERR
	end

	return _CFG
end

local function init_unveil(optcfg)
	local cfg = optcfg or assert(getcfg())

	if not cfg.enabled then
		module:log("info", "unveil disabled")
		return true
	end

	if not can_unveil() then
		error("process has already been pledged (try including error or unveil promise)")
	end

	if cfg.warnings then
		local status, err = pcall(check_install, cfg.paths)
		if status ~= true then
			module:log("warn", "error checking install: %s", err)
		end
	end

	local unveiled = {}
	for path, permissions in cfg.paths do
		module:log("info", "unveiling %s (%s)", path, permissions)
		local ok, err = openbsd.unveil(path, permissions)
		if not ok then
			module:log("error", "failed to unveil %s: %s", path, err)
		else
			unveiled[path] = permissions
		end
	end

	-- Seal paths early as one of our main concerns is modules
	-- potentially loading untrusted code, e.g. from /var/prosody.
	assert(openbsd.unveil())
	module:log("info", "unveil sealed")

	_STATE.unveiled = unveiled

	return true
end

local function onerror(err)
	local cfg = getcfg(true)

	if cfg.exitonerror then
		module:log("error", "%s", tostring(err))
		os.exit(1)
	else
		error(err, 0)
	end
end

-- module exports
function module.load()
	module:log("debug", "running load method")

	if module.reloading or _STATE.loaded then
		return
	end

	xpwrap(function ()
		assert(init_unveil())
	end, onerror)()

	_STATE.loaded = true

	return true
end

function module.save()
	module:log("debug", "running save method")

	return _STATE
end

function module.restore(state)
	module:log("debug", "running restore method")

	_STATE = state
end

function module.unload()
	module:log("debug", "running unload method")

	if not module.reloading then
		module:log("warn", "unloading not supported (cannot reset or restore process state)")
	end
end
