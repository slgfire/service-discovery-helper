# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Service Discovery Helper (SDH) is a UDP broadcast forwarder written in C. It listens on specified network interfaces for UDP broadcast packets on whitelisted ports and retransmits them to all other configured interfaces. Primary use case: enabling game server discovery across VLANs at LAN parties.

## Build

```bash
make                # builds sdh-proxy binary in repo root
```

Requires `gcc`, `libpcap`, and `libpcap-dev`. No test suite exists.

## Run

```bash
sudo ./sdh-proxy -c config/sdh-proxy.conf.example    # config file
sudo ./sdh-proxy -p config/ports -i config/interfaces -r    # legacy CLI flags
```

Requires root (or pcap capture privileges).

## Repository Structure

```
src/            C source code (sdh-proxy, timer, log, config)
config/         Configuration files (ports, interfaces, sdh-proxy.conf.example)
deploy/         Deployment files (Dockerfile, compose.yaml, sdh-proxy.service)
lib/uthash/     Vendored header-only hash table library
.github/        CI/CD workflows
```

## Architecture

- **src/sdh-proxy.c / sdh-proxy.h** — Main program. Parses CLI args or config file, builds a BPF filter string from the port list, opens pcap handles per interface, and spawns one pthread per interface running `pcap_loop` → `flood_packet`. Signal handler (SIGTERM/SIGINT) triggers graceful shutdown via `do_exit` flag and `pcap_breakloop()`.

- **src/timer.c / timer.h** — Optional rate limiter. Uses a hash table (uthash) keyed on `{source IP, dest UDP port}` to track recently forwarded packets. A background purge thread cleans expired entries. Thread safety via `pthread_rwlock_t`.

- **src/log.c / log.h** — Centralized logging with `sdh_log()`. Supports stdout (with timestamps) and syslog backends. Three levels: ERROR, INFO, DEBUG.

- **src/config.c / config.h** — INI-style config parser. Sections: `[interfaces]` (list), `[ports]` (list), `[settings]` (key=value).

- **lib/uthash/** — Vendored header-only hash table library (Troy Hanson's uthash). Used only by timer.

## Key Constants (src/sdh-proxy.h)

- `MAX_IFACES 256`, `MAX_PORTS 2048` — static array limits
- `SNAP_LEN 1540` — max packet capture length

## Branches

- `master` — stable v1.x release
- `v2.0` — v2.0 with config file, logging, signal handling, Docker, systemd
