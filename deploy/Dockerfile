# syntax=docker/dockerfile:1.7
FROM rust:1-bookworm AS build
WORKDIR /src
RUN apt-get update && apt-get install -y --no-install-recommends pkg-config libssl-dev && rm -rf /var/lib/apt/lists/*
COPY Cargo.toml Cargo.lock rust-toolchain.toml ./
COPY crates ./crates
COPY migrations ./migrations
RUN cargo build --release -p nntdrive-backend -p nntdrive-cli && \
    cp target/release/nntdrive-backend /usr/local/bin/nntdrive-backend && \
    cp target/release/nntdrive /usr/local/bin/nntdrive

FROM debian:bookworm-slim
ARG VERSION=dev
LABEL org.opencontainers.image.title="NNTDrive backend" \
      org.opencontainers.image.description="Self-hosted end-to-end encrypted storage on Usenet" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.licenses="AGPL-3.0-or-later"
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && \
    rm -rf /var/lib/apt/lists/* && \
    useradd --system --uid 10001 --home /var/lib/nntdrive nntdrive
COPY --from=build /usr/local/bin/nntdrive-backend /usr/local/bin/nntdrive-backend
COPY --from=build /usr/local/bin/nntdrive /usr/local/bin/nntdrive
RUN mkdir -p /var/lib/nntdrive/cache && chown -R nntdrive:nntdrive /var/lib/nntdrive
USER 10001
ENV NNTDRIVE_BIND=0.0.0.0:8080 \
    NNTDRIVE_CACHE_DIR=/var/lib/nntdrive/cache \
    RUST_LOG=info,sqlx=warn
EXPOSE 8080
VOLUME ["/var/lib/nntdrive/cache"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8080/healthz || exit 1
ENTRYPOINT ["/usr/local/bin/nntdrive-backend"]
