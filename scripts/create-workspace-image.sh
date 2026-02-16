#!/bin/bash
# =============================================================================
# Create Workspace Block Device Image
# =============================================================================
# Creates an ext4 image from host directory for mounting in VM.
# =============================================================================

set -euo pipefail

SOURCE_DIR="${1:?Usage: create-workspace-image.sh <source_dir> <output_image> [size_mb]}"
OUTPUT_IMAGE="${2:?Usage: create-workspace-image.sh <source_dir> <output_image> [size_mb]}"
SIZE_MB="${3:-2048}"

# Calculate required size (source + 20% overhead, minimum SIZE_MB)
if [ -d "$SOURCE_DIR" ]; then
    SOURCE_SIZE_KB=$(du -sk "$SOURCE_DIR" 2>/dev/null | cut -f1)
    SOURCE_SIZE_MB=$((SOURCE_SIZE_KB / 1024))
    REQUIRED_MB=$((SOURCE_SIZE_MB * 120 / 100))  # 20% overhead
    
    if [ "$REQUIRED_MB" -gt "$SIZE_MB" ]; then
        SIZE_MB="$REQUIRED_MB"
        echo "Adjusting workspace size to ${SIZE_MB}MB to fit content"
    fi
fi

# Create image
truncate -s ${SIZE_MB}M "$OUTPUT_IMAGE"
mkfs.ext4 -F "$OUTPUT_IMAGE" >/dev/null 2>&1

# Mount and sync content
MOUNT_POINT=$(mktemp -d)
cleanup_mount() {
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        umount "$MOUNT_POINT" || true
    fi
    rmdir "$MOUNT_POINT" 2>/dev/null || true
}
trap cleanup_mount EXIT

mount -o loop "$OUTPUT_IMAGE" "$MOUNT_POINT"

if [ -d "$SOURCE_DIR" ] && [ "$(ls -A "$SOURCE_DIR" 2>/dev/null)" ]; then
    rsync -av "$SOURCE_DIR/" "$MOUNT_POINT/"
    
    # Fix ownership (sandbox user in VM is UID 1000)
    chown -R 1000:1000 "$MOUNT_POINT" || true
fi

umount "$MOUNT_POINT"
trap - EXIT
cleanup_mount

echo "Workspace image created: $OUTPUT_IMAGE (${SIZE_MB}MB)"
