-- =====================================================================
-- mod_ktrace.lua - Prosody OpenBSD tracing module
-- ---------------------------------------------------------------------
-- Copyright (c) 2026 William Ahern
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
local posix = require"prosody.util.pposix"
local sformat = string.format

local activetracefile = nil
local activetimer = nil

local function xpwrap(f, optmsgh)
	local msgh = optmsgh or function (err, ...)
		return err, ...
	end
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

local function istype(v, ...)
	local function test(what, typename, ...)
		if typename then
			if what == typename then
				return true
			end
			return test(what, ...)
		else
			return false
		end
	end

	return test(type(v), ...)
end

local function optfield(t, name, def, expected, ...)
	expected = expected or type(def)

	local v = t[name]
	if v == nil then
		return def
	elseif not istype(v, expected, ...) then
		module:log("wrong type for .%s (expected %s, got %s)", table.concat({ expected, ...}, ", "), type(v))
		return def
	else
		return v
	end
end

local _DEFAULT_TRACEPOINTS = openbsd.KTRFAC_SYSCALL
		           | openbsd.KTRFAC_NAMEI
		           | openbsd.KTRFAC_PLEDGE
		           | openbsd.KTRFAC_USER
		           | openbsd.KTRFAC_INHERIT
local function totracepoint(s)
	local minus, name = s:upper():match"^(-?)(.*)"
	if name == "DEFAULT" then
		return _DEFAULT_TRACEPOINTS, (minus == "-")
	else
		local symbol = name:match"^KTRFAC_.+" or "KTRFAC_" .. name
		return openbsd[symbol], (minus == "-")
	end
end

local function totracepoints(s)
	if type(s) == "number" then
		return s & openbsd.KTRFAC_MASK
	end

	local trpoints = 0
	for w in s:gmatch"[-_%w]+" do
		local fac, minus = totracepoint(w)
		if not fac then
			module:log("%s: invalid tracepoint", w)
		elseif minus then
			trpoints = trpoints & ~fac;
		else
			trpoints = trpoints | fac;
		end
	end
	return trpoints
end

local function strtracepoints(trpoints)
	local list = {}
	for k,v in pairs(openbsd) do
		if tostring(k):match"^KTRFAC_" and (trpoints & v) == v then
			list[#list + 1] = tostring(k)
		end
	end

	return table.concat(list, " ")
end

local function parsecfg(v)
	local cfg = {
		duration = nil,
		enabled = false,
		tracefile = nil,
		tracepoints = totracepoints("DEFAULT"),
	}

	if not v then
		cfg.enabled = false
	elseif type(v) == "boolean" then
		cfg.enabled = true
	elseif type(v) == "table" then
		cfg.duration = optfield(v, "duration", cfg.duration, "number")
		cfg.enabled = optfield(v, "enabled", true, "boolean")
		cfg.tracefile = optfield(v, "tracefile", cfg.tracefile, "string")
		cfg.tracepoints = totracepoints(optfield(v, "tracepoints", cfg.tracepoints, "number", "string"))
	else
		module:log("bad config type (expected boolean or table, got %s)", type(v))
		cfg.enabled = false
	end

	return cfg
end

local _CFG = nil
local function getcfg()
	if not _CFG then
		_CFG = assert(parsecfg(module:get_option("ktrace", false)))
	end
	return _CFG
end

local function createtracefile(path, withflags)
	local oflags = openbsd.O_CREAT
	             | openbsd.O_WRONLY
	             | (withflags or 0)
	local mode = openbsd.S_IRUSR -- owner read
	           | openbsd.S_IWUSR -- owner write

	local fd, err = openbsd.open(path, oflags, mode)
	if not fd then
		return false, sformat("%s: unable to create trace file: %s", path, err)
	end

	local ok, err = openbsd.close(fd)
	if not ok then
		return false, sformat("%s: unable to close trace file descriptor: %s", path, err)
	end

	return path
end

local function preptracefile(path)
	if not path then
		-- if generating a path use O_EXCL to be safe, especially
		-- given we're writing to the data directory
		local datadir = assert(prosody.paths.data)
		local uniquepath = sformat("%s/ktrace-%s-%d.out", datadir, os.date("%Y%m%dT%H%M%S"), posix.getpid())
		return createtracefile(uniquepath, assert(openbsd.O_EXCL))
	else
		-- if caller specified a path at least use O_NOFOLLOW, which
		-- is what ktrace(2) expects, anyhow
		return createtracefile(path, assert(openbsd.O_NOFOLLOW))
	end
end

local stop = xpwrap(function ()
	local tracefile = activetracefile

	if not tracefile then
		return true
	end

	if activetimer then
		activetimer:stop()
		activetimer = nil
	end

	-- FIXME: Skip if we're pledged, otherwise we might kill the
	-- process. There's no pledge for ktrace, though utrace is always
	-- allowed.

	-- Don't need KTRFLAG_DESCEND, trpoints, or PID when using
	-- KTROP_CLEARFILE. See doktrace in sys/kern/kern_ktrace.c.
	local ok, err = openbsd.ktrace(tracefile, openbsd.KTROP_CLEARFILE, 0, 0)
	if not ok then
		return false, sformat("%s: unable to stop tracing: %s", tracefile, err)
	end

	activetracefile = nil
	module:log("info", "stopped tracing")
	return true
end)

local start = xpwrap(function (optpath, opttracepoints, optduration)
	if activetracefile then
		if optpath == nil or optpath == activetracefile then
			return true
		end

		local ok, err = stop()
		if not ok then
			return false, err
		end
	end

	-- ktrace requires passing path to preexisting file
	local tracefile, err = preptracefile(optpath or getcfg().tracefile)
	if not tracefile then
		return false, err
	end

	local ops = openbsd.KTROP_SET
	          | openbsd.KTRFLAG_DESCEND
	local trpoints = totracepoints(opttracepoints or getcfg().tracepoints)
	local ok, err = openbsd.ktrace(tracefile, ops, trpoints, posix.getpid())
	if not ok then
		return false, sformat("%s: unable to start tracing: %s", tracefile, err)
	end

	activetracefile = tracefile
	local duration = optduration or getcfg().duration
	activetimer = duration and module:add_timer(duration, function ()
		module:log("info", "tracing timer expired")
		local ok, err = stop()
		if not ok then
			module:log("error", "%s", err)
		end
	end)

	module:log("info", "tracing to %s", tracefile)
	return true
end)

-- module initialization
do
	module:set_global()

	if getcfg().enabled then
		local ok, err = start()
		if not ok then
			module:log("error", "%s", err)
		end
	end
end
