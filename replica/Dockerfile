# Combined verifier image for a single Render Docker service.
# Build context: replica/
# Mount genesis.json + rollup.json at /config/ (pack-replica-artifacts.sh; Render secret files).
FROM us-docker.pkg.dev/oplabs-tools-artifacts/images/op-geth:v1.101702.2 AS geth

FROM us-docker.pkg.dev/oplabs-tools-artifacts/images/op-node:v1.19.2

USER root
RUN apt-get update && apt-get install -y --no-install-recommends openssl ca-certificates \
  && rm -rf /var/lib/apt/lists/* \
  && mkdir -p /config

COPY --from=geth /usr/local/bin/geth /usr/local/bin/geth
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV DATA_DIR=/data \
    L2_HTTP_PORT=8545 \
    L2_AUTH_PORT=8551 \
    L2_NODE_RPC_PORT=9545 \
    L1_BLOCK_TIME=12 \
    GENESIS=/config/genesis.json \
    ROLLUP=/config/rollup.json

VOLUME ["/data", "/config"]
EXPOSE 8545 9545

ENTRYPOINT ["/entrypoint.sh"]
