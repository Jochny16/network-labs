# A minimal "server": Debian + python3 (Ansible modules run with Python on the target)
ARG BASE_IMAGE=debian:trixie-slim
FROM ${BASE_IMAGE}
RUN apt-get update && apt-get install -y --no-install-recommends python3 \
    && rm -rf /var/lib/apt/lists/*
CMD ["sleep", "infinity"]
