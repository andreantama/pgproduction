#!/bin/sh
set -e

MINIO_ENDPOINT=${MINIO_ENDPOINT:-http://minio:9000}
MINIO_ROOT_USER=${MINIO_ROOT_USER:-minioadmin}
MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD:-minioadmin123}
BUCKET_NAME=${BUCKET_NAME:-pg-backups}

echo "Waiting for MinIO to be ready..."
until mc --insecure alias set myminio "${MINIO_ENDPOINT}" "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASSWORD}" 2>/dev/null; do
    echo "MinIO not ready, retrying in 5 seconds..."
    sleep 5
done

echo "MinIO is ready. Initializing bucket..."

# Create bucket if it doesn't exist
if ! mc --insecure ls "myminio/${BUCKET_NAME}" > /dev/null 2>&1; then
    mc --insecure mb "myminio/${BUCKET_NAME}"
    echo "Bucket '${BUCKET_NAME}' created successfully."
else
    echo "Bucket '${BUCKET_NAME}' already exists."
fi

# Set bucket policy (optional: make it private)
mc --insecure anonymous set none "myminio/${BUCKET_NAME}"

echo "MinIO initialization complete."
