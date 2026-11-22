PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
CFLAGS ?= -O2 -Wall -Wextra

blink: blink.m
	$(CC) $(CFLAGS) -fobjc-arc -o $@ $< -framework Foundation

test: blink
	./tests/run.sh ./blink

install: blink
	install -d $(DESTDIR)$(BINDIR)
	install -m 755 blink $(DESTDIR)$(BINDIR)/blink

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/blink

clean:
	rm -f blink

.PHONY: test install uninstall clean
