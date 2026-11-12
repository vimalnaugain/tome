# Desktop development build: tomecore.so for the system LuaJIT.
# The Kindle build is tools/build_kindle.sh.
LUAJIT_INC ?= $(shell pkg-config --cflags luajit 2>/dev/null || echo -I/usr/include/luajit-2.1)
CFLAGS ?= -O2 -Wall -Wextra -std=gnu99

tomecore.so: tomecore.c
	$(CC) $(CFLAGS) $(LUAJIT_INC) -shared -fPIC -o $@ $<

clean:
	rm -f tomecore.so

.PHONY: clean
