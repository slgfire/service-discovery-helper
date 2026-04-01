# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Service Discovery Helper (SDH) is a UDP broadcast forwarder written in C. It listens on specified network interfaces for UDP broadcast packets on whitelisted ports and retransmits them to all other configured interfaces. Primary use case: enabling game server discovery across VLANs at LAN parties.

## Build

```bash
make                # builds sdh-proxy binary
```

Requires `gcc`, `libpcap`, and `libpcap-dev`. No test suite exists.

## Run

```bash
sudo ./sdh-proxy -p ports -i interfaces [-r] [-t ms] [-l] [-d]
```

Requires root (or pcap capture privileges). Use `-a` instead of `-i` to auto-detect all interfaces.

## Architecture

The codebase is small (~850 lines across 4 source files):

- **sdh-proxy.c / sdh-proxy.h** — Main program. Parses CLI args, reads config files (`ports`, `interfaces`), builds a BPF filter string from the port list, opens pcap handles per interface, and spawns one pthread per interface running `pcap_loop` → `flood_packet`. The flood function copies each received broadcast and injects it on every other interface via `pcap_inject`.

- **timer.c / timer.h** — Optional rate limiter. Uses a hash table (uthash) keyed on `{source IP, dest UDP port}` to track recently forwarded packets. A background purge thread cleans expired entries. Thread safety via `pthread_rwlock_t`.

- **uthash/** — Vendored header-only hash table library (Troy Hanson's uthash). Used only by timer.c.

- **ports / interfaces** — Plain text config files, one entry per line. `#` for comments. Ports support ranges (`27015-27020`). See `GAMES.md` for tested game ports.

## Key Constants (sdh-proxy.h)

- `MAX_IFACES 256`, `MAX_PORTS 2048` — static array limits
- `SNAP_LEN 1540` — max packet capture length
- Filter string buffer is hardcoded at 10000 bytes (`generate_filter_string`)

## Known Issues

- Segfault with very large port files (workaround: split into multiple files/instances)
- Segfault if run without root privileges
- `iface_list[num_ifaces] = malloc(strlen(...))` in `use_all_pcap_ints` is off-by-one (missing +1 for null terminator)
