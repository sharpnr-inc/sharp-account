# Container image for sharp-account.
#
#   docker build -t sharp-account .
#
# Two stages:
#   1. `build`   - full Rust toolchain, compiles a release binary.
#   2. `runtime` - small Debian image with only the binary, running as a
#                  non-root user. No compiler, no source code, no secrets.
#
# Secrets are never baked into the image. Configuration comes from environment
# variables, and signing keys from a volume mounted at /var/lib/sharp-account/keys.
# See compose.yaml for a complete local setup and docs/deployment.md for details.

ARG RUST_VERSION=1.97

# ---------------------------------------------------------------------------
# Stage 1: build
# ---------------------------------------------------------------------------
FROM rust:${RUST_VERSION}-slim-trixie AS build
WORKDIR /app

# Dependency layer: build all third-party crates against placeholder sources.
# This layer is only rebuilt when Cargo.toml or Cargo.lock change, so editing
# our own code does not recompile ~300 dependencies. (Works with the classic
# builder too; no BuildKit-only features.)
COPY Cargo.toml Cargo.lock ./
RUN mkdir src \
    && echo 'fn main() {}' > src/main.rs \
    && touch src/lib.rs \
    && cargo build --release --locked \
    && rm -rf src

# Application layer: our real sources.
COPY src ./src
# Migrations are embedded into the binary by `sqlx::migrate!` at compile time.
COPY migrations ./migrations
# HTML templates are compiled into the binary by Askama, so they are needed to
# build (and never shipped in the runtime image).
COPY templates ./templates
# The favicon is compiled in with `include_str!`. Only this folder is copied;
# the brand kit in assets/brand is for people, not the build.
COPY assets/web ./assets/web
# `touch` makes sure Cargo sees the real files as newer than the placeholders.
RUN touch src/main.rs src/lib.rs \
    && cargo build --release --locked --bin sharp-account \
    && cp target/release/sharp-account /usr/local/bin/sharp-account

# ---------------------------------------------------------------------------
# Stage 2: runtime
# ---------------------------------------------------------------------------
# Debian 13 (trixie) is the current stable release. The runtime must use the
# same Debian release as the build stage (`rust:...-slim-trixie`): the binary is
# linked against the build image's glibc and will not start on an older one.
FROM debian:trixie-slim AS runtime

# Ensure all system packages are up-to-date to address known vulnerabilities
RUN apt-get update && apt-get upgrade -y && apt-get clean && rm -rf /var/lib/apt/lists/*

# A fixed, unprivileged UID so volume permissions are predictable.
ARG APP_UID=10001
RUN useradd --system --uid ${APP_UID} --no-create-home --shell /usr/sbin/nologin sharp-account \
    && mkdir -p /var/lib/sharp-account/keys \
    && chown -R sharp-account:sharp-account /var/lib/sharp-account \
    && chmod 700 /var/lib/sharp-account/keys

COPY --from=build /usr/local/bin/sharp-account /usr/local/bin/sharp-account

# Container defaults. DATABASE_URL and ISSUER_URL have no safe default and
# must be provided at runtime.
ENV HOST=0.0.0.0 \
    PORT=3000 \
    SIGNING_KEYS_DIR=/var/lib/sharp-account/keys \
    RUST_LOG=info,sqlx=warn

USER sharp-account
WORKDIR /var/lib/sharp-account
VOLUME ["/var/lib/sharp-account/keys"]
EXPOSE 3000

HEALTHCHECK --interval=10s --timeout=5s --start-period=15s --retries=3 \
    CMD ["sharp-account", "healthcheck"]

# `docker run sharp-account` starts the server; any other command is passed to
# the CLI, e.g. `docker run sharp-account create-client --name ...`.
ENTRYPOINT ["sharp-account"]
CMD ["serve"]
