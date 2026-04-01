CC ?= gcc
SRC = src/sdh-proxy.c src/timer.c src/log.c src/config.c
INCLUDES = -Isrc -Ilib

all:
	$(CC) -Wall -g -std=gnu99 $(INCLUDES) -o sdh-proxy $(SRC) -lpthread -lpcap

PREFIX ?= /usr/local
SYSCONFDIR ?= /etc
SYSTEMD_UNIT_DIR ?= /lib/systemd/system

install: all
	install -D -m 755 sdh-proxy $(DESTDIR)$(PREFIX)/bin/sdh-proxy
	install -D -m 644 deploy/sdh-proxy.service $(DESTDIR)$(SYSTEMD_UNIT_DIR)/sdh-proxy.service
	test -f $(DESTDIR)$(SYSCONFDIR)/sdh-proxy.conf || install -D -m 644 config/sdh-proxy.conf.example $(DESTDIR)$(SYSCONFDIR)/sdh-proxy.conf

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/sdh-proxy
	rm -f $(DESTDIR)$(SYSTEMD_UNIT_DIR)/sdh-proxy.service
	# Config file intentionally not removed (preserves user changes)

clean:
	rm -f sdh-proxy
