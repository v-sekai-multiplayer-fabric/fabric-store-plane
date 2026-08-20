# The store: SQLite with a VFS whose pages live in FoundationDB.
#
# Three stages, and each exists for one reason. iceoryx2 keeps the Rust toolchain out of
# the runtime image. The build stage carries the FoundationDB and SQLite headers. The
# runtime carries neither compiler.
#
#   fly deploy --config fly/fly.toml
ARG ICEORYX2_VERSION=0.9.3
ARG FDB_VERSION=7.3.76

FROM docker.io/library/rust:1.90-bookworm AS iceoryx
ARG ICEORYX2_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends cmake ca-certificates curl \
  && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL "https://github.com/eclipse-iceoryx/iceoryx2/archive/refs/tags/v${ICEORYX2_VERSION}.tar.gz" \
      | tar -xz -C /tmp \
  && cmake -S "/tmp/iceoryx2-${ICEORYX2_VERSION}" -B /tmp/ice-build \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/iceoryx -DBUILD_EXAMPLES=OFF \
  && cmake --build /tmp/ice-build -j \
  && cmake --install /tmp/ice-build \
  && rm -rf /tmp/ice-build "/tmp/iceoryx2-${ICEORYX2_VERSION}"

FROM docker.io/library/debian:bookworm-slim AS build
ARG FDB_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends \
      cmake make gcc g++ python3 libsqlite3-dev curl ca-certificates \
  && curl -fsSL -o /tmp/fdb.deb \
      "https://github.com/apple/foundationdb/releases/download/${FDB_VERSION}/foundationdb-clients_${FDB_VERSION}-1_amd64.deb" \
  && dpkg -i /tmp/fdb.deb && rm /tmp/fdb.deb \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY . /src
RUN cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build -j

FROM docker.io/library/debian:bookworm-slim
ARG FDB_VERSION
RUN apt-get update && apt-get install -y --no-install-recommends \
      libstdc++6 libsqlite3-0 curl ca-certificates \
  && curl -fsSL -o /tmp/fdb.deb \
      "https://github.com/apple/foundationdb/releases/download/${FDB_VERSION}/foundationdb-clients_${FDB_VERSION}-1_amd64.deb" \
  && dpkg -i /tmp/fdb.deb && rm /tmp/fdb.deb \
  && apt-get purge -y curl && rm -rf /var/lib/apt/lists/*
COPY --from=iceoryx /opt/iceoryx /opt/iceoryx
COPY --from=build /src/build/ /usr/local/lib/store/
ENV LD_LIBRARY_PATH=/opt/iceoryx/lib64
ENV WEFT_FDB_CLUSTER_FILE=/etc/foundationdb/fdb.cluster
CMD ["/bin/sh", "-c", "ls /usr/local/lib/store"]
