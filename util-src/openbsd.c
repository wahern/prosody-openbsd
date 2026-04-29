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
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
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

#include <fcntl.h>  /* O_* open(2) openat(2) */
#include <unistd.h> /* close(2) getcwd(3) pledge(2) unveil(2) */

#include <sys/param.h>  /* MAXCOMLEN */
#include <sys/ktrace.h> /* ktrace(2) utrace(2) */
#include <sys/stat.h>   /* S_* */

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
	C(KTRFAC_MASK),
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

	/* open flags */
	C(O_ACCMODE),
	C(O_APPEND),
	C(O_CLOEXEC),
	C(O_CLOFORK),
	C(O_CREAT),
	C(O_DIRECTORY),
	C(O_DSYNC),
	C(O_EXCL),
#ifdef O_EXEC
	C(O_EXEC),
#endif
	C(O_NOCTTY),
	C(O_NOFOLLOW),
	C(O_NONBLOCK),
	C(O_RDONLY),
	C(O_RDWR),
	C(O_RSYNC),
#ifdef O_SEARCH
	C(O_SEARCH),
#endif
	C(O_SYNC),
	C(O_TRUNC),
#ifdef O_TTY_INIT
	C(O_TTY_INIT),
#endif
	C(O_WRONLY),

	/* file mode bits */
	C(S_IFMT),
	C(S_IFBLK),
	C(S_IFCHR),
	C(S_IFIFO),
	C(S_IFREG),
	C(S_IFDIR),
	C(S_IFLNK),
	C(S_IFSOCK),
	C(S_IRWXU),
	C(S_IRUSR),
	C(S_IWUSR),
	C(S_IXUSR),
	C(S_IRWXG),
	C(S_IRGRP),
	C(S_IWGRP),
	C(S_IXGRP),
	C(S_IRWXO),
	C(S_IROTH),
	C(S_IWOTH),
	C(S_IXOTH),
	C(S_ISUID),
	C(S_ISGID),
	C(S_ISVTX),

	/* BSD file flags */
	C(UF_NODUMP),
	C(UF_IMMUTABLE),
	C(UF_APPEND),
	C(SF_ARCHIVED),
	C(SF_IMMUTABLE),
	C(SF_APPEND),
};

static int errnoresult(lua_State *L, int error)
{
	luaL_pushfail(L);
	lua_pushstring(L, strerror(error));
	lua_pushinteger(L, error);
	return 3;
}

static int
Lclose(lua_State *L)
{
	int fd = (int)luaL_checkinteger(L, 1);

	if (0 != close(fd)) {
		return errnoresult(L, errno);
	}

	lua_pushboolean(L, 1);
	return 1;
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
Lgeteuid(lua_State *L)
{
	lua_pushinteger(L, geteuid());
	return 1;
}

static int
Lgetgid(lua_State *L)
{
	lua_pushinteger(L, getgid());
	return 1;
}

static int
Lgetgroups(lua_State *L)
{
	gid_t groups[NGROUPS_MAX];
	int n;

	if ((n = getgroups(sizeof groups / sizeof *groups, groups)) < 0) {
		return errnoresult(L, errno);
	}

	lua_createtable(L, n, 0);
	for (int i = 0; i < n; i++) {
		lua_pushinteger(L, groups[i]);
		lua_rawseti(L, -2, i + 1);
	}
	return 1;
}

static int
Lgetuid(lua_State *L)
{
	lua_pushinteger(L, getuid());
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
Lgetegid(lua_State *L)
{
	lua_pushinteger(L, getegid());
	return 1;
}

static inline double
ts2f(struct timespec ts) {
	return ts.tv_sec + (ts.tv_nsec / 1000000000.0);
}

static void
pushstat(lua_State *L, const struct stat *st)
{
	lua_newtable(L);

	lua_pushinteger(L, st->st_dev);
	lua_setfield(L, -2, "st_dev");

	lua_pushinteger(L, st->st_ino);
	lua_setfield(L, -2, "st_ino");

	lua_pushinteger(L, st->st_mode);
	lua_setfield(L, -2, "st_mode");

	lua_pushinteger(L, st->st_nlink);
	lua_setfield(L, -2, "st_nlink");

	lua_pushinteger(L, st->st_uid);
	lua_setfield(L, -2, "st_uid");

	lua_pushinteger(L, st->st_gid);
	lua_setfield(L, -2, "st_gid");

	lua_pushinteger(L, st->st_rdev);
	lua_setfield(L, -2, "st_rdev");

	lua_pushinteger(L, st->st_size);
	lua_setfield(L, -2, "st_size");

	lua_pushnumber(L, ts2f(st->st_atim));
	lua_setfield(L, -2, "st_atim");

	lua_pushnumber(L, ts2f(st->st_mtim));
	lua_setfield(L, -2, "st_mtim");

	lua_pushnumber(L, ts2f(st->st_ctim));
	lua_setfield(L, -2, "st_ctim");

	lua_pushinteger(L, st->st_blksize);
	lua_setfield(L, -2, "st_blksize");

	lua_pushinteger(L, st->st_blocks);
	lua_setfield(L, -2, "st_blocks");

	lua_pushinteger(L, st->st_flags);
	lua_setfield(L, -2, "st_flags");
}

static int
Llstat(lua_State *L)
{
	const char *path = luaL_checkstring(L, 1);
	struct stat st = { 0 };

	if (0 != lstat(path, &st)) {
		return errnoresult(L, errno);
	}

	pushstat(L, &st);
	return 1;
}

static int
Lopen(lua_State *L)
{
	const char *path = luaL_checkstring(L, 1);
	int oflags = (int)luaL_checkinteger(L, 2);
	mode_t mode = (oflags & O_CREAT)? luaL_checkinteger(L, 3) : 0;
	int fd;

	if (-1 == (fd = open(path, oflags, mode))) {
		return errnoresult(L, errno);
	}

	lua_pushinteger(L, fd);
	return 1;
}

static int
Lopenat(lua_State *L)
{
	int dirfd = (int)luaL_checkinteger(L, 1);
	const char *path = luaL_checkstring(L, 2);
	int oflags = (int)luaL_checkinteger(L, 3);
	mode_t mode = (oflags & O_CREAT)? luaL_checkinteger(L, 4) : 0;
	int fd;

	if (-1 == (fd = openat(dirfd, path, oflags, mode))) {
		return errnoresult(L, errno);
	}

	lua_pushinteger(L, fd);
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
Lstat(lua_State *L)
{
	const char *path = luaL_checkstring(L, 1);
	struct stat st = { 0 };

	if (0 != stat(path, &st)) {
		return errnoresult(L, errno);
	}

	pushstat(L, &st);
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
	{ "close", &Lclose },
	{ "getcwd", &Lgetcwd },
	{ "getegid", &Lgetegid },
	{ "geteuid", &Lgeteuid },
	{ "getgid", &Lgetgid },
	{ "getgroups", &Lgetgroups },
	{ "getuid", &Lgetuid },
	{ "ktrace", &Lktrace },
	{ "lstat", &Llstat },
	{ "open", &Lopen },
	{ "openat", &Lopenat },
	{ "pledge", &Lpledge },
	{ "stat", &Lstat },
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
