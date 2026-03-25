FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    gnupg \
    lsb-release \
    ca-certificates \
    sudo \
    python3 \
    python3-pip \
    python3-dev \
    libpq-dev \
    gcc \
    && rm -rf /var/lib/apt/lists/*

# Add PostgreSQL APT repository
RUN curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg \
    && echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list

# Install PostgreSQL 15 and pgBackRest
RUN apt-get update && apt-get install -y \
    postgresql-15 \
    postgresql-client-15 \
    postgresql-contrib-15 \
    pgbackrest \
    && rm -rf /var/lib/apt/lists/*

# Install Patroni and dependencies
RUN pip3 install --no-cache-dir \
    patroni[etcd3] \
    psycopg2-binary \
    python-etcd \
    python-dateutil

# Create directories
RUN mkdir -p /var/lib/postgresql/data \
    && mkdir -p /etc/patroni \
    && mkdir -p /var/log/patroni \
    && mkdir -p /var/log/pgbackrest \
    && mkdir -p /var/lib/pgbackrest \
    && mkdir -p /var/spool/pgbackrest \
    && mkdir -p /etc/pgbackrest \
    && chown -R postgres:postgres /var/lib/postgresql \
    && chown -R postgres:postgres /var/log/patroni \
    && chown -R postgres:postgres /var/log/pgbackrest \
    && chown -R postgres:postgres /var/lib/pgbackrest \
    && chown -R postgres:postgres /var/spool/pgbackrest

# Create entrypoint script
COPY entrypoint.sh /entrypoint.sh
COPY post_bootstrap.sh /usr/local/bin/post_bootstrap.sh
RUN chmod +x /entrypoint.sh /usr/local/bin/post_bootstrap.sh

EXPOSE 5432 8008

USER postgres

ENTRYPOINT ["/entrypoint.sh"]
