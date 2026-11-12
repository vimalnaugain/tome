/*
 * Integer <-> float helpers that LuaJIT references by their generic libgcc
 * names (lj_ircall.h). Zig's compiler-rt for ARM EABI only exports the
 * __aeabi_* variants, so provide the generic ones as thin, weak wrappers
 * (weak: if a toolchain does ship them, its versions win).
 */
__attribute__((weak)) double __floatdidf(long long a) { return (double)a; }
__attribute__((weak)) double __floatundidf(unsigned long long a) { return (double)a; }
__attribute__((weak)) float __floatdisf(long long a) { return (float)a; }
__attribute__((weak)) float __floatundisf(unsigned long long a) { return (float)a; }
