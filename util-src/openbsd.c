/* =====================================================================
 * openbsd.c - Prosody OpenBSD Lua C API bindings
 * ---------------------------------------------------------------------
 * Copyright (c) 2022 William Ahern
 *
 * Permission is hereby granted, free of charge, to any person obtaining
 * a copy of this software and associated documentation files (the
 * "Software"), to deal in the Software without restriction, including
 * without limitation the rights to use, copy, modify, merge, publish,
 * distribute, sublicense, and/or sell copies of the Software, and to
 * permit persons to whom the Software is furnished to do so, subject to
 * the following conditions:

 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.

 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
 * IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
 * CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
 * TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
 * SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 * ======================================================================
 */
#include <errno.h>  /* errno */
#include <string.h> /* strerror(3) strlen(3) */

#include <unistd.h> /* getcwd(3) pledge(2) unveil(2) */

#include <sys/param.h>  /* MAXCOMLEN */
#include <sys/ktrace.h> /* ktrace(2) utrace(2) */

#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#define countof(array) (sizeof (array) / sizeof (array)[0])

#if LUA_VERSION_NUM < 504
#define luaL_pushfail lua_pushnil
#endif

#define C(x) { #x, x }
static const struct {
	char name[24];
	lua_Integer value;
} constants[] = {
	/* ktrace(2) ops */
	C(KTROP_SET),
	C(KTROP_CLEAR),
	C(KTROP_CLEARFILE),
	C(KTRFLAG_DESCEND),

	/* ktrace(2) trpoints */
	C(KTRFAC_SYSCALL),
	C(KTRFAC_SYSRET),
	C(KTRFAC_NAMEI),
	C(KTRFAC_GENIO),
	C(KTRFAC_PSIG),
	C(KTRFAC_STRUCT),
	C(KTRFAC_USER),
	C(KTRFAC_EXECARGS),
	C(KTRFAC_EXECENV),
	C(KTRFAC_PLEDGE),
	C(KTRFAC_INHERIT),

	/* struct ktr_header */
	C(KTR_START),
	C(KTR_SYSCALL),
	C(KTR_SYSRET),
	C(KTR_NAMEI),
	C(KTR_GENIO),
	C(KTR_PSIG),
	C(KTR_STRUCT),
	C(KTR_USER),
	C(KTR_EXECARGS),
	C(KTR_EXECENV),
	C(KTR_PLEDGE),
	C(MAXCOMLEN),

	/* struct ktr_user */
	C(KTR_USER_MAXIDLEN),
	C(KTR_USER_MAXLEN),
};

static int errnoresult(lua_State *L, int error)
{
	luaL_pushfail(L);
	lua_pushstring(L, strerror(error));
	lua_pushinteger(L, error);
	return 3;
}

static int
Lgetcwd(lua_State *L)
{
	/*
	 * NB: being careful not to leak memory if pushing result throws:
	 * using luaL_Buffer rather than letting getcwd(3) allocate and
	 * return a buffer
	 */
	luaL_Buffer b;
	luaL_buffinit(L, &b);

	const char *path;
	if (!(path = getcwd(luaL_prepbuffer(&b), LUAL_BUFFERSIZE))) {
		return errnoresult(L, errno);
	}

	luaL_addsize(&b, strlen(path));
	luaL_pushresult(&b);
	return 1;
}

static int
Lktrace(lua_State *L)
{
	const char *tracefile = luaL_checkstring(L, 1);
	int ops = (int)luaL_checkinteger(L, 2);
	int trpoints = (int)luaL_checkinteger(L, 3);
	pid_t pid = (pid_t)luaL_checkinteger(L, 4);

	if (0 != ktrace(tracefile, ops, trpoints, pid)) {
		return errnoresult(L, errno);
	}

	lua_pushboolean(L, 1);
	return 1;
}

static int
Lpledge(lua_State *L)
{
	const char *promises = luaL_optstring(L, 1, NULL);
	const char *execpromises = luaL_optstring(L, 2, NULL);

	if (0 != pledge(promises, execpromises)) {
		return errnoresult(L, errno);
	}

	lua_pushboolean(L, 1);
	return 1;
}

static int
Lunveil(lua_State *L)
{
	const char *path = luaL_optstring(L, 1, NULL);
	const char *permissions = luaL_optstring(L, 2, NULL);

	if (0 != unveil(path, permissions)) {
		return errnoresult(L, errno);
	}

	lua_pushboolean(L, 1);
	return 1;
}

static int
Lutrace(lua_State *L)
{
	const char *label = luaL_checkstring(L, 1);
	size_t rlen = 0;
	const char *record = luaL_optlstring(L, 2, NULL, &rlen);

	if (0 != utrace(label, record, rlen)) {
		return errnoresult(L, errno);
	}

	lua_pushboolean(L, 1);
	return 1;
}

static const luaL_Reg exports[] = {
	{ "getcwd", &Lgetcwd },
	{ "ktrace", &Lktrace },
	{ "pledge", &Lpledge },
	{ "unveil", &Lunveil },
	{ "utrace", &Lutrace },
	{ NULL, NULL }
};

int
luaopen_util_openbsd(lua_State *L)
{
	lua_newtable(L);

	for (size_t i = 0; i < countof(constants); i++) {
		lua_pushstring(L, constants[i].name);
		lua_pushinteger(L, constants[i].value);
		lua_settable(L, -3);
	}

#if LUA_VERSION_NUM < 502
	luaL_register(L, NULL, exports);
#else
	luaL_setfuncs(L, exports, 0);
#endif

	return 1;
}
