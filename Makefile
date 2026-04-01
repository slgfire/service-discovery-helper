CC ?= gcc

all:
	$(CC) -Wall -g -std=gnu99 -o sdh-proxy sdh-proxy.c timer.c log.c config.c -lpthread -lpcap

PREFIX ?= /usr/local
SYSCONFDIR ?= /etc
SYSTEMD_UNIT_DIR ?= /lib/systemd/system

install: all
	install -D -m 755 sdh-proxy $(DESTDIR)$(PREFIX)/bin/sdh-proxy
	install -D -m 644 sdh-proxy.service $(DESTDIR)$(SYSTEMD_UNIT_DIR)/sdh-proxy.service
	test -f $(DESTDIR)$(SYSCONFDIR)/sdh-proxy.conf || install -D -m 644 sdh-proxy.conf.example $(DESTDIR)$(SYSCONFDIR)/sdh-proxy.conf

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/sdh-proxy
	rm -f $(DESTDIR)$(SYSTEMD_UNIT_DIR)/sdh-proxy.service
	# Config file intentionally not removed (preserves user changes)

clean:
	rm -f sdh-proxy
