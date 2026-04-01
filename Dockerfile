FROM debian:bookworm-slim AS builder
RUN apt-get update && \
    apt-get install -y --no-install-recommends gcc make libpcap-dev libc6-dev && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . .
RUN make

FROM debian:bookworm-slim
RUN apt-get update && \
    apt-get install -y --no-install-recommends libpcap0.8 && \
    rm -rf /var/lib/apt/lists/*
COPY --from=builder /src/sdh-proxy /usr/local/bin/sdh-proxy
COPY sdh-proxy.conf.example /etc/sdh-proxy.conf
ENTRYPOINT ["sdh-proxy", "-c", "/etc/sdh-proxy.conf"]
