#!/bin/bash
# =============================================================================
# Build firecracker-base image
# =============================================================================
# Requires privileged build for loop mount during rootfs creation.
# Uses docker buildx with security.insecure flag.
# =============================================================================

set -e

IMAGE_NAME="${1:-firecracker-base:latest}"

echo "Building $IMAGE_NAME..."
echo ""

# Check if buildx is available
if ! docker buildx version &>/dev/null; then
    echo "Error: docker buildx not available"
    echo "Install with: docker buildx install"
    exit 1
fi

# Create or use existing builder with docker-container driver
BUILDER_NAME="firecracker-builder"
if ! docker buildx inspect "$BUILDER_NAME" &>/dev/null; then
    echo "Creating buildx builder: $BUILDER_NAME"
    docker buildx create --name "$BUILDER_NAME" --driver docker-container --bootstrap
fi

# Build with privileged mode (required for loop mount)
echo "Building with privileged mode (required for loop mount)..."
echo ""

docker buildx build \
    --builder "$BUILDER_NAME" \
    --load \
    --allow security.insecure \
    --build-arg FIRECRACKER_VERSION=v1.6.0 \
    --build-arg ROOTFS_SIZE_MB=8192 \
    -t "$IMAGE_NAME" \
    .

echo ""
echo "Build complete: $IMAGE_NAME"
echo ""
echo "Run with:"
echo "  docker compose run --rm firecracker-base"
