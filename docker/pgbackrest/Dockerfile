FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install pgBackRest and dependencies
RUN apt-get update && apt-get install -y \
    pgbackrest \
    curl \
    ca-certificates \
    cron \
    && rm -rf /var/lib/apt/lists/*

# Create directories
RUN mkdir -p /var/lib/pgbackrest \
    && mkdir -p /var/log/pgbackrest \
    && mkdir -p /etc/pgbackrest \
    && mkdir -p /var/spool/pgbackrest

# Create postgres user (same UID as in patroni container)
RUN groupadd -r postgres --gid=999 && \
    useradd -r -g postgres --uid=999 --home-dir=/var/lib/postgresql --shell=/bin/bash postgres

# Set permissions
RUN chown -R postgres:postgres /var/lib/pgbackrest \
    && chown -R postgres:postgres /var/log/pgbackrest \
    && chown -R postgres:postgres /var/spool/pgbackrest \
    && chmod 750 /var/lib/pgbackrest \
    && chmod 750 /var/log/pgbackrest

# Copy entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER postgres

ENTRYPOINT ["/entrypoint.sh"]
