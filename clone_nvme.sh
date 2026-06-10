#!/usr/bin/env bash
# Exit immediately if a command exits with a non-zero status
set -e

# --- CONFIGURATION ---
# IMPORTANT: Double-check your drive names! 
# Use 'lsblk' to ensure correct identification.
SRC="/dev/nvme0n1"
DST="/dev/nvme1n1"

echo "=== WARNING ==="
echo "This will irreversibly overwrite all data on $DST"
read -p "Are you sure you want to proceed? (y/N): " confirm

if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Cloning cancelled."
    exit 1
fi

echo "Step 1: Unmounting any mounted partitions on source and destination..."
sudo umount ${SRC}* 2>/dev/null || true
sudo umount ${DST}* 2>/dev/null || true

echo "Step 2: Cloning disk layout and data..."
# Using 'dd' to copy the exact partition table and raw data
sudo dd if="$SRC" of="$DST" bs=4M status=progress conv=fsync

echo "Step 3: Informing the kernel of the new partition table size..."
sudo partprobe "$DST"

echo "=== UUID FIX & RESIZE ==="
echo "Generating new UUIDs to prevent conflicts since both drives are connected."

# Generate a random UUID for the new cloned root/BTRFS partition
# (Assuming the main OS is partition 3. Adjust based on your lsblk output)
ROOT_PART="${DST}p3"
NEW_UUID=$(uuidgen)
sudo btrfs filesystem tune --uuid "$NEW_UUID" "$ROOT_PART"

echo "Step 4: Mounting the cloned filesystem to resize..."
TEMP_MOUNT="/mnt/fedora_clone"
sudo mkdir -p "$TEMP_MOUNT"
sudo mount -t btrfs -o uuid="$NEW_UUID" "$ROOT_PART" "$TEMP_MOUNT"

echo "Step 5: Expanding BTRFS partition to fill the 4 TB drive..."
# This resizes the filesystem to use 100% of the expanded partition
sudo btrfs filesystem resize max "$TEMP_MOUNT"

echo "Step 6: Unmounting the drive..."
sudo umount "$TEMP_MOUNT"

echo "=== CLONE COMPLETE ==="
echo "Please shut down, remove the old 1 TB drive, and boot from the new 4 TB drive."

