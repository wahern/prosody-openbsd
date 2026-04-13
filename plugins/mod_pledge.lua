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

	function promiselist:has(promise)
		return (self.inner:exists(promise))
	end

	function promiselist.new()
		local self = {
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

local pledge_enabled = module:get_option("pledge", true)
local activepromises = nil

local function init_pledge()
	local promises = promiselist.new()

	promises:add(_PROMISES_INIT)

	if type(pledge_enabled) == "string" then
		promises:add(pledge_enabled)
	end

	local s = table.concat(promises.inner:getlist(), " ")
	module:log("info", "pledging %s", s)
	assert(openbsd.pledge(s))
	activepromises = promises
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
	activepromises = promises

	assert(openbsd.pledge())
	module:log("info", "pledge sealed")
end

local function on_error(err)
	module:log("error", "%s", tostring(err))

	-- bail on load error rather than leave process unguarded
	os.exit(1)
end

local init_sandbox = xpwrap(function ()
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

-- module exports
function is_enabled()
	return pledge_enabled
end

function is_pledged(promise)
	if not activepromises then
		return false
	elseif not promise then
		return true
	else
		return (activepromises:has(promise))
	end
end
