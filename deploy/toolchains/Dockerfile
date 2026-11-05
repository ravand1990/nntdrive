# syntax=docker/dockerfile:1
# Deliberate local snapshot; CI still follows rolling Rust stable.
FROM ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852 AS rust
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git xz-utils unzip build-essential pkg-config libssl-dev \
    clang cmake ninja-build libgtk-3-dev liblzma-dev postgresql-client \
    && rm -rf /var/lib/apt/lists/*
ENV RUSTUP_HOME=/opt/rust/rustup CARGO_HOME=/opt/rust/cargo
ENV PATH=/opt/rust/cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o /tmp/rustup.sh \
    && sh /tmp/rustup.sh -y --profile minimal --default-toolchain 1.99.1 --component rustfmt,clippy \
    && rm /tmp/rustup.sh && chmod -R a+rX /opt/rust
ENV RUSTUP_TOOLCHAIN=1.99.1 CARGO_HOME=/state/cargo HOME=/state/home
WORKDIR /src
CMD ["rustc", "--version"]

FROM rust AS flutter
ARG FLUTTER_VERSION=3.47.9
ARG FLUTTER_SHA256=25ed8c3c29d51a7353f2a944310b478af8214920639524b19c50a19e6c044c5a
ENV PATH=/opt/flutter/bin:$PATH PUB_CACHE=/state/pub FLUTTER_SUPPRESS_ANALYTICS=true
# Keep extraction, permissions and pruning in one layer: a later recursive chmod
# would duplicate multiple GiB of SDK files in an OCI image.
RUN curl -fL --retry 3 "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" -o /tmp/flutter.tar.xz \
    && echo "${FLUTTER_SHA256}  /tmp/flutter.tar.xz" | sha256sum -c - \
    && tar -xJf /tmp/flutter.tar.xz -C /opt && rm /tmp/flutter.tar.xz \
    && git config --system --add safe.directory /opt/flutter \
    && flutter config --no-analytics --enable-linux-desktop \
    && flutter precache --linux --no-android --no-web --no-ios --no-macos --no-windows \
    && rm -rf /opt/flutter/bin/cache/artifacts/engine/android* /opt/flutter/bin/cache/flutter_web_sdk \
    && chmod -R a+rwX /opt/flutter/bin/cache /opt/flutter/packages/flutter_tools/.dart_tool
CMD ["flutter", "--version"]
