#!/bin/sh
# ============================================================
# MinIO Bucket Initialization Script
# Creates the pg-backups bucket if it doesn't exist
# ============================================================

set -e

MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://minio:9000}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-minioadmin123}"
BUCKET_NAME="${BUCKET_NAME:-pg-backups}"
MAX_RETRIES=30
RETRY_INTERVAL=5

echo "MinIO Init: Waiting for MinIO to start..."
echo "  Endpoint: ${MINIO_ENDPOINT}"
echo "  Bucket:   ${BUCKET_NAME}"

attempt=1
while [ $attempt -le $MAX_RETRIES ]; do
    if mc alias set myminio "${MINIO_ENDPOINT}" "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" > /dev/null 2>&1; then
        echo "MinIO Init: Connected to MinIO successfully."
        break
    fi
    echo "MinIO Init: Attempt ${attempt}/${MAX_RETRIES} - MinIO not ready, waiting ${RETRY_INTERVAL}s..."
    sleep $RETRY_INTERVAL
    attempt=$((attempt + 1))
done

if [ $attempt -gt $MAX_RETRIES ]; then
    echo "MinIO Init: ERROR - Could not connect to MinIO after ${MAX_RETRIES} attempts."
    exit 1
fi

# Create bucket if it doesn't exist
if mc ls "myminio/${BUCKET_NAME}" > /dev/null 2>&1; then
    echo "MinIO Init: Bucket '${BUCKET_NAME}' already exists."
else
    mc mb "myminio/${BUCKET_NAME}"
    echo "MinIO Init: Bucket '${BUCKET_NAME}' created successfully."
fi

# Set bucket versioning (optional, helps with backup management)
# mc version enable "myminio/${BUCKET_NAME}"

echo "MinIO Init: Initialization complete."
