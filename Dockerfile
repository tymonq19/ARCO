# Arco server image (SPEC §1, §4).
#
#   docker build -t arco-server .
#   docker run --rm -p 8080:8080 -v arco_data:/app/data arco-server
#
# Stage 1 compiles the pure-Dart server ahead of time, stage 2 ships the
# resulting bundle on a slim Debian with the system SQLite.
#
# NOTE: `dart compile exe` cannot be used here - package:sqlite3 3.x ships a
# native-assets build hook and `dart compile` refuses those ("'dart compile'
# does not support build hooks, use 'dart build' instead"). `dart build cli`
# produces the same AOT executable inside a bundle directory.

# ---------------------------------------------------------------- build
FROM dart:stable AS build

# package:sqlite3 is configured (server/pubspec.yaml, `hooks.user_defines`) to
# link against the operating system's SQLite instead of downloading a prebuilt
# library, so the build needs the development package.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# Resolve dependencies first: this layer is cached until a pubspec changes.
COPY packages/arco_core/pubspec.yaml packages/arco_core/
COPY server/pubspec.yaml server/pubspec.lock server/
WORKDIR /src/server
RUN dart pub get

# Then the sources.
WORKDIR /src
COPY packages/arco_core/ packages/arco_core/
COPY server/ server/
WORKDIR /src/server
RUN dart pub get --offline \
    && dart build cli --output /out \
    && ls -l /out/bundle/bin/server

# ---------------------------------------------------------------- runtime
FROM debian:bookworm-slim AS runtime

# libsqlite3-0 only ships the versioned `libsqlite3.so.0`, while the AOT binary
# resolves the linker name `libsqlite3.so` (normally provided by -dev), so the
# symlink is added by hand instead of pulling in the development package.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libsqlite3-0 \
    && rm -rf /var/lib/apt/lists/* \
    && SQLITE_SO="$(ldconfig -p | awk '/libsqlite3\.so\.0/ {print $NF; exit}')" \
    && test -n "$SQLITE_SO" \
    && ln -sf "$SQLITE_SO" "$(dirname "$SQLITE_SO")/libsqlite3.so" \
    && ldconfig \
    && groupadd --system --gid 10001 arco \
    && useradd --system --uid 10001 --gid arco --home-dir /app \
       --shell /usr/sbin/nologin arco \
    && mkdir -p /app/data \
    && chown -R arco:arco /app

# bundle/bin/server plus bundle/lib/ for any bundled native library.
COPY --from=build --chown=arco:arco /out/bundle /app/bundle

# The SQLite database lives here; mount a volume to keep the leaderboard.
VOLUME ["/app/data"]

ENV PORT=8080 \
    DB_PATH=/app/data/arco.db \
    VERIFY_REPLAYS=strict \
    LOG_LEVEL=info

EXPOSE 8080
USER arco
WORKDIR /app
ENTRYPOINT ["/app/bundle/bin/server"]
