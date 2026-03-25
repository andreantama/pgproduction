FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install pgBackRest from PGDG repo (newer version with PostgreSQL 15 support)
RUN apt-get update && apt-get install -y \
    curl \
    ca-certificates \
    gnupg \
    lsb-release \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update && apt-get install -y \
    pgbackrest \
    postgresql-client-15 \
    && rm -rf /var/lib/apt/lists/*

# Install supercronic (user-space cron daemon — no root required)
ARG SUPERCRONIC_VERSION=0.2.29
RUN curl -fsSL "https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/supercronic-linux-amd64" \
    -o /usr/local/bin/supercronic \
    && chmod +x /usr/local/bin/supercronic

# Create directories
RUN mkdir -p /var/lib/pgbackrest \
    && mkdir -p /var/log/pgbackrest \
    && mkdir -p /etc/pgbackrest \
    && mkdir -p /var/spool/pgbackrest

# Create postgres user (same UID as in patroni container) if not already present
RUN getent group postgres || groupadd -r postgres --gid=999
RUN getent passwd postgres || useradd -r -g postgres --uid=999 --home-dir=/var/lib/postgresql --shell=/bin/bash postgres

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
