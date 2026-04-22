-- =====================================================================
-- mod_pledge.lua - Prosody OpenBSD sandboxing module
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
-- Ensure ktrace is loaded, if at all, before us as there is no pledge
-- promise for allowing ktrace(2).
module:depends("ktrace", true)

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
-- TODO: Duplicated from mod_unveil. Put into separate util module?
local orderedmap = {}; do
	orderedmap.__index = orderedmap
	orderedmap.__name = "ordered map"

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

	function orderedmap.__len(self)
		return self.n
	end

	function orderedmap:keys()
		return next, self.index, nil
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
			self.n = self.n + 1
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
		if self.index[k] ~= nil then
			self.index[k] = nil
			self.dirty = true
			self.n = self.n - 1
		end

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
			n = 0,
		}
		return setmetatable(self, orderedmap)
	end
end

local promiselist = {}; do
	promiselist.__index = promiselist
	promiselist.__name = "promise list"

	function promiselist.__call(self, _, previousindex)
		return self.inner(_, previousindex)
	end

	-- equal if same set of promises
	function promiselist.__eq(a, b)
		if #a.inner ~= #b.inner then
			return false
		end

		for k in a.inner:keys() do
			if not b.inner:exists(k) then
				return false
			end
		end

		return true
	end

	function promiselist.__tostring(self)
		return table.concat(self.inner:getlist(), " ")
	end

	local function selfresult(self, r, ...)
		if r then return self, ... else return r, ... end
	end

	local function add1(self, promise)
		return selfresult(self, self.inner:insert(promise))
	end

	local function delete1(self, promise)
		return selfresult(self, self.inner:delete(promise))
	end

	local function gsplit(s)
		return coroutine.wrap(function ()
			for promise in s:gmatch"[^%s]+" do
				if promise:match"^-." then
					coroutine.yield(promise:sub(2), true, promise)
				else
					coroutine.yield(promise, false, promise)
				end
			end
		end)
	end

	local function delete(self, s, nodefault)
		local lasterr = nil

		for promise, negated, what in gsplit(s) do
			local ok, err

			if nodefault and promise == "DEFAULT" then
				ok, err = false, "DEFAULT promise in delete operation"
			elseif negated then
				ok, err = false, sformat("negated promise in delete operation (%q expected, got %q)", promise, what)
			else
				ok, err = delete1(self, promise)
			end

			if not ok then
				module:log("error", "unable to delete %q promise: %s", what, err or "?")
				lasterr = err or lasterr or "?"
			end
		end

		return selfresult(self, not lasterr, lasterr)
	end

	local function add(self, s, nodefault)
		local lasterr = nil

		for promise, negated, what in gsplit(s) do
			local ok, err

			if promise == "DEFAULT" then
				if nodefault then
					ok, err = false, "recursive use of DEFAULT promise detected"
				elseif negated then
					ok, err = delete(self, self.default, true)
				else
					ok, err = add(self, self.default, true)
				end
			elseif negated then
				ok, err = delete1(self, promise)
			else
				ok, err = add1(self, promise)
			end

			if not ok then
				module:log("error", "unable to add %q promise: %s", what, err or "?")
				lasterr = err or lasterr or "?"
			end
		end

		return selfresult(self, not lasterr, lasterr)
	end

	function promiselist:add(s1, s2, ...)
		local ok, err = add(self, s1)
		if not ok then
			return false, err or "?"
		elseif s2 then
			return self:add(s2, ...)
		else
			return self
		end
	end

	function promiselist:delete(s1, s2, ...)
		local ok, err = delete(self, s1)
		if not ok then
			return false, err or "?"
		elseif s2 then
			return self:delete(s2, ...)
		else
			return self
		end
	end

	function promiselist:has(promise)
		return (self.inner:exists(promise))
	end

	function promiselist.type(o)
		return getmetatable(o) == promiselist and promiselist.__name
	end

	function promiselist.new(default)
		local self = {
			default = default or "",
			inner = orderedmap.new(),
		}
		return setmetatable(self, promiselist)
	end
end

-- The flock and proc pledges are required initially for mod_posix
-- daemonization (presuming we're loaded early enough), then we can drop.
-- Also include unveil initially in case mod_unveil is loaded after us.
-- NB: Unlike unveil, subsequent pledges cannot expand capabilities.
local _PROMISES_SEAL = "stdio rpath wpath cpath inet dns"
local _PROMISES_INIT = _PROMISES_SEAL .. " flock proc prot_exec unveil"

-- see save and restore module methods
local _STATE = {
	loaded = false,
	sealed = false,
	promised = nil,
}

local function parsecfg(v)
	local cfg = {
		init = nil,
		seal = nil,
	}
	local err

	if v == true then
		cfg.init, err = promiselist.new(_PROMISES_INIT):add("DEFAULT")
		if err then return false, err end
		cfg.seal, err = promiselist.new(_PROMISES_SEAL):add("DEFAULT")
		if err then return false, err end
	elseif v == false then
		cfg.init = false
		cfg.seal = false
	elseif type(v) == "string" then
		cfg.init, err = promiselist.new(_PROMISES_INIT):add("DEFAULT", v)
		if err then return false, err end
		cfg.seal, err = promiselist.new(_PROMISES_SEAL):add("DEFAULT", v)
		if err then return false, err end
	elseif type(v) == "table" then
		local function choose(s, default, what)
			if s == nil or s == true then
				return promiselist.new(default):add("DEFAULT")
			elseif type(s) == "string" then
				return promiselist.new(default):add(s)
			elseif s == false then
				return false
			else
				return nil, sformat("bad config %s field (expected string, boolean, or nil, got %s)", what, type(s))
			end
		end
		local r

		cfg.init, err = choose(v.init, _PROMISES_INIT, ".init")
		if err then return false, err end
		cfg.seal, err = choose(v.seal, _PROMISES_SEAL, ".seal")
		if err then return false, err end
	elseif type(v) ~= "boolean" then
		return false, sformat("bad config type (expected boolean, string or table, got %s)", type(v))
	end

	assert(cfg.init == false or promiselist.type(cfg.init))
	assert(cfg.seal == false or promiselist.type(cfg.seal))

	return cfg
end

local _CFG = nil
local function getcfg()
	if not _CFG then
		_CFG = assert(parsecfg(module:get_option("pledge", true)))
	end
	return _CFG
end

local function init_pledge(optcfg)
	local cfg = assert(optcfg or getcfg())
	if not cfg.init then
		module:log("info", "skipping initial pledge (disabled)")
		return true
	end

	local s = tostring(cfg.init)
	module:log("info", "pledging %s", s)
	assert(openbsd.pledge(s))
	_STATE.promised = cfg.init

	return true
end

local function seal_pledge(optcfg)
	local cfg = assert(optcfg or getcfg())
	if not cfg.seal then
		module:log("info", "skipping pledge sealing (disabled)")
		return true
	end

	local s = tostring(cfg.seal)
	module:log("info", "pledging %s", s)
	assert(openbsd.pledge(s))
	_STATE.promised = cfg.seal

	assert(openbsd.pledge())
	_STATE.sealed = true
	module:log("info", "pledge sealed")

	return true
end

local function die(err)
	module:log("error", "%s", tostring(err))
	-- bail on load error rather than leave process unguarded
	os.exit(1)
end

-- module exports
function module.load()
	module:log("debug", "running load method")

	if module.reloading or _STATE.loaded then
		return
	end

	xpwrap(function ()
		assert(init_pledge())
	end, die)()

	_STATE.loaded = true

	module:hook_global("server-started", xpwrap(function ()
		assert(seal_pledge())
	end, die), -99)
end

function module.save()
	module:log("debug", "running save method")

	local cfg = assert(getcfg())
	-- save promiselists as strings so code references don't persist
	return {
		init = cfg.init and tostring(cfg.init) or false,
		seal = cfg.seal and tostring(cfg.seal) or false,
		sealed = _STATE.sealed,
		promised = _STATE.promised and tostring(_STATE.promised) or nil,
	}
end

function module.restore(prior)
	module:log("debug", "running restore method")

	assert(prior)

	local cfg = assert(getcfg())
	local prior_init = prior.init and assert(promiselist.new():add(prior.init)) or false
	local prior_seal = prior.seal and assert(promiselist.new():add(prior.seal)) or false
	if prior_init ~= cfg.init or prior_seal ~= cfg.seal then
		module:log("warn", "modified configurations cannot be applied across reloads")
	end

	_STATE = {
		loaded = prior.loaded,
		sealed = prior.sealed,
		promised = prior.promised and assert(promiselist.new():add(prior.promised)) or nil,
	}
end

function module.unload()
	module:log("debug", "running unload method")

	if not module.reloading then
		module:log("warn", "unloading not supported (cannot reset or restore process state)")
	end
end

function is_pledged(promise)
	if not _STATE.promised then
		return false
	elseif not promise then
		return true
	else
		return (_STATE.promised:has(promise))
	end
end
