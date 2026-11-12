/*
 * Kindle entry point: a statically linked LuaJIT with tomecore preloaded.
 * Usage: tome <script.lua> [args...]
 */
#include <stdio.h>
#include <stdlib.h>

#include "lauxlib.h"
#include "lua.h"
#include "lualib.h"

int luaopen_tomecore(lua_State *L);

static int traceback(lua_State *L) {
    const char *msg = lua_tostring(L, 1);
    luaL_traceback(L, L, msg ? msg : "(error object is not a string)", 1);
    return 1;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s script.lua [args...]\n", argv[0]);
        return 2;
    }
    lua_State *L = luaL_newstate();
    if (!L) return 1;
    luaL_openlibs(L);

    lua_getglobal(L, "package");
    lua_getfield(L, -1, "preload");
    lua_pushcfunction(L, luaopen_tomecore);
    lua_setfield(L, -2, "tomecore");
    lua_pop(L, 2);

    lua_createtable(L, argc, 0);
    for (int i = 0; i < argc; i++) {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i - 1); /* arg[0] = script, like lua(1) */
    }
    lua_setglobal(L, "arg");

    lua_pushcfunction(L, traceback);
    if (luaL_loadfile(L, argv[1]) != 0) {
        fprintf(stderr, "%s\n", lua_tostring(L, -1));
        return 1;
    }
    for (int i = 2; i < argc; i++) lua_pushstring(L, argv[i]);
    int status = lua_pcall(L, argc - 2, 0, 1);
    if (status != 0) {
        fprintf(stderr, "%s\n", lua_tostring(L, -1));
        lua_close(L);
        return 1;
    }
    lua_close(L);
    return 0;
}
