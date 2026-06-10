#!/usr/bin/env bash
# NVMe Clone Script - Version 0.4.0
# Fedora 44 Compatible NVMe Cloning Tool
# Exit immediately if a command exits with a non-zero status
set -e

# --- ERROR HANDLING ---
# Cleanup on exit
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        echo ""
        echo "⚠️  ERROR: Script failed with exit code $exit_code"
        echo "Attempting to unmount temporary mount point..."
        sudo umount /mnt/fedora_clone 2>/dev/null || true
    fi
    exit $exit_code
}
trap cleanup EXIT

# --- VALIDATE FEDORA 44 REQUIREMENTS ---
validate_requirements() {
    local missing_tools=()
    
    # Check for required commands
    for cmd in lsblk dd partprobe btrfs uuidgen awk grep; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_tools+=("$cmd")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        echo "Error: The following required tools are not installed:"
        for tool in "${missing_tools[@]}"; do
            echo "  - $tool"
        done
        echo ""
        echo "On Fedora 44, install missing tools with:"
        echo "  sudo dnf install util-linux e2fsprogs btrfs-progs util-linux"
        exit 1
    fi
    
    # Check if running with sudo/root access
    if [[ $EUID -ne 0 ]] && ! sudo -n true 2>/dev/null; then
        echo "Error: This script requires sudo access."
        echo "Please ensure you can run sudo commands without a password prompt,"
        echo "or run the script with: sudo bash $0"
        exit 1
    fi
}

# --- DRY RUN MODE ---
DRY_RUN=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "OPTIONS:"
            echo "  --dry-run     Show what would happen without making any changes"
            echo "  --help        Display this help message"
            echo ""
            echo "This script clones one NVMe drive to another, including:"
            echo "  - Copying all data and partition layout"
            echo "  - Updating filesystem UUIDs to avoid conflicts"
            echo "  - Resizing the filesystem to fill the destination drive"
            echo ""
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Run validation checks on startup
validate_requirements

# Function to execute or display commands based on dry-run mode
execute_or_show() {
    if [[ "$DRY_RUN" == true ]]; then
        echo "[DRY-RUN] $@"
    else
        "$@"
    fi
}

# --- INTERACTIVE DEVICE SELECTION ---

# Function to list available NVMe devices
list_nvme_devices() {
    lsblk -d -n -o NAME,SIZE,SERIAL | grep "^nvme" | sort
}

# Function to display menu and get user selection
select_device() {
    local prompt="$1"
    local exclude_device="$2"
    local devices=()
    local device_info=()
    
    # Build array of available devices
    while IFS= read -r line; do
        local device=$(echo "$line" | awk '{print $1}')
        
        # Skip if it matches the excluded device
        if [[ "$exclude_device" != "" && "$device" == "$exclude_device" ]]; then
            continue
        fi
        
        devices+=("$device")
        device_info+=("$line")
    done < <(list_nvme_devices)
    
    if [[ ${#devices[@]} -eq 0 ]]; then
        echo "Error: No available NVMe devices found."
        exit 1
    fi
    
    echo ""
    echo "=============================================="
    echo "$prompt"
    echo "=============================================="
    echo ""
    
    # Show numbered list of devices
    local count=1
    for info in "${device_info[@]}"; do
        echo "[$count] $info"
        count=$((count + 1))
    done
    echo ""
    
    local choice
    while true; do
        read -p "Enter your selection (1-${#devices[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#devices[@]} )); then
            echo "/dev/${devices[$((choice - 1))]}"
            return
        else
            echo "Invalid selection. Please try again (enter a number between 1 and ${#devices[@]})."
        fi
    done
}


# Show available devices
if [[ "$DRY_RUN" == true ]]; then
    echo "╔════════════════════════════════════════════════════════════════════╗"
    echo "║                     DRY-RUN MODE ENABLED                          ║"
    echo "║   No actual changes will be made to your drives                    ║"
    echo "║   This will show you exactly what would happen                     ║"
    echo "╚════════════════════════════════════════════════════════════════════╝"
    echo ""
fi

echo "=== AVAILABLE NVMe DEVICES ==="
echo "The following NVMe devices are available on your system:"
echo ""
list_nvme_devices
echo ""

# Select source device
echo "STEP 1: SELECT SOURCE DEVICE"
echo "You will be cloning FROM this device."
echo "⚠️  This device will NOT be modified."
echo ""
SRC=$(select_device "Which device contains the data you want to clone?")

# Select destination device (exclude source)
echo "STEP 2: SELECT DESTINATION DEVICE"
echo "You will be cloning TO this device."
echo "⚠️  WARNING: ALL DATA on this device will be permanently overwritten!"
echo ""
DST=$(select_device "Which device should receive the clone?" "$(basename $SRC)")

# Validate selection
if [[ "$SRC" == "$DST" ]]; then
    echo "Error: Source and destination cannot be the same device."
    exit 1
fi

echo ""
echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║                    CLONE CONFIGURATION SUMMARY                    ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""
echo "Source Device:      $SRC"
echo "                    (This will be READ - no changes)"
echo ""
echo "Destination Device: $DST"
echo "                    (This will be OVERWRITTEN - all data will be lost)"
echo ""

echo "Operations that will be performed:"
echo "  1. Unmount any mounted partitions on both devices"
echo "  2. Copy all data and partition layout from $SRC to $DST (using dd)"
echo "  3. Update partition table on $DST"
echo "  4. Generate new unique filesystem UUIDs on $DST"
echo "     (prevents conflicts when both drives are connected)"
echo "  5. Mount the cloned filesystem"
echo "  6. Expand the filesystem to use full capacity of $DST"
echo "  7. Unmount the cloned filesystem"
echo ""

if [[ "$DRY_RUN" == true ]]; then
    echo "DRY-RUN: No changes will be made. Showing commands that would execute:"
    echo ""
else
    echo "⚠️  FINAL WARNING ⚠️"
    echo "This operation is IRREVERSIBLE. All data on $DST will be destroyed."
    echo ""
    read -p "Are you absolutely sure you want to proceed? (type 'yes' to confirm): " confirm
    
    if [[ "$confirm" != "yes" ]]; then
        echo "Cloning cancelled."
        exit 1
    fi
    echo ""
fi

echo "Step 1: Unmounting any mounted partitions on source and destination..."
if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] Would unmount: ${SRC}* from the system"
    echo "[DRY-RUN] Would unmount: ${DST}* from the system"
    echo "[DRY-RUN] Command: sudo umount ${SRC}* 2>/dev/null || true"
    echo "[DRY-RUN] Command: sudo umount ${DST}* 2>/dev/null || true"
else
    sudo umount ${SRC}* 2>/dev/null || true
    sudo umount ${DST}* 2>/dev/null || true
fi
echo ""

echo "Step 2: Cloning disk layout and data..."
echo "        This copies every bit from $SRC to $DST (4MB blocks)"
echo "        This may take several minutes depending on drive size..."
if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] Would execute: sudo dd if=\"$SRC\" of=\"$DST\" bs=4M status=progress conv=fsync"
    echo "[DRY-RUN] This copies all partitions, filesystems, and data from source to destination"
else
    # Using 'dd' to copy the exact partition table and raw data
    sudo dd if="$SRC" of="$DST" bs=4M status=progress conv=fsync
fi
echo ""

echo "Step 3: Informing the kernel of the new partition table size..."
if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] Would execute: sudo partprobe \"$DST\""
    echo "[DRY-RUN] This makes the kernel recognize the new partition layout on $DST"
else
    sudo partprobe "$DST"
fi
echo ""

echo "=== UUID FIX & RESIZE ==="
echo "Detecting BTRFS filesystems on the cloned drive..."
echo ""

# Detect BTRFS partitions automatically
detect_btrfs_partition() {
    local device="$1"
    local btrfs_part=""
    
    # Try to find the largest BTRFS partition on the device
    for partition in "${device}"p*; do
        if [[ -b "$partition" ]]; then
            # Check if partition is BTRFS without mounting
            if sudo blkid -s TYPE "$partition" 2>/dev/null | grep -q "TYPE=\"btrfs\""; then
                btrfs_part="$partition"
                # Return the last (usually largest) BTRFS partition found
            fi
        fi
    done
    
    echo "$btrfs_part"
}

ROOT_PART=$(detect_btrfs_partition "$DST")

if [[ -z "$ROOT_PART" ]]; then
    echo "Error: No BTRFS filesystem found on $DST"
    echo "The cloned drive may not have a BTRFS filesystem, or the clone failed."
    echo "Please verify the drive manually with: sudo lsblk -f $DST"
    exit 1
fi

echo "Detected BTRFS partition: $ROOT_PART"
echo ""

NEW_UUID=$(uuidgen)

echo "Step 4: Creating unique filesystem UUID for the clone..."
echo "        New UUID: $NEW_UUID"
if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] Would execute: sudo btrfs filesystem tune --uuid \"$NEW_UUID\" \"$ROOT_PART\""
    echo "[DRY-RUN] This gives the cloned filesystem a unique identifier"
else
    sudo btrfs filesystem tune --uuid "$NEW_UUID" "$ROOT_PART"
fi
echo ""

echo "Step 5: Mounting the cloned filesystem to prepare for resize..."
TEMP_MOUNT="/mnt/fedora_clone"
if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] Would create directory: $TEMP_MOUNT"
    echo "[DRY-RUN] Would execute: sudo mkdir -p \"$TEMP_MOUNT\""
    echo "[DRY-RUN] Would execute: sudo mount -t btrfs -o uuid=\"$NEW_UUID\" \"$ROOT_PART\" \"$TEMP_MOUNT\""
    echo "[DRY-RUN] This temporarily mounts the cloned filesystem"
else
    # Clean up any existing mount point
    sudo umount "$TEMP_MOUNT" 2>/dev/null || true
    sudo mkdir -p "$TEMP_MOUNT"
    
    # Mount with error checking
    if ! sudo mount -t btrfs -o uuid="$NEW_UUID" "$ROOT_PART" "$TEMP_MOUNT" 2>/dev/null; then
        echo "Error: Failed to mount $ROOT_PART at $TEMP_MOUNT"
        echo "Try mounting manually to diagnose: sudo mount -t btrfs $ROOT_PART /mnt/test"
        exit 1
    fi
fi
echo ""

echo "Step 6: Expanding BTRFS filesystem to fill the entire $DST drive..."
if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] Would execute: sudo btrfs filesystem resize max \"$TEMP_MOUNT\""
    echo "[DRY-RUN] This expands the filesystem to use 100% of the available space on $DST"
else
    # This resizes the filesystem to use 100% of the expanded partition
    sudo btrfs filesystem resize max "$TEMP_MOUNT"
fi
echo ""

echo "Step 7: Unmounting the cloned filesystem..."
if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] Would execute: sudo umount \"$TEMP_MOUNT\""
    echo "[DRY-RUN] This safely disconnects the cloned filesystem"
else
    sudo umount "$TEMP_MOUNT"
fi
echo ""

echo "╔════════════════════════════════════════════════════════════════════╗"
if [[ "$DRY_RUN" == true ]]; then
    echo "║                    DRY-RUN COMPLETE                             ║"
    echo "║                 No changes were actually made                    ║"
    echo "║         Run again without --dry-run to perform the clone        ║"
else
    echo "║                    CLONE COMPLETE                               ║"
    echo "║  Please shut down, remove the old drive, and boot from new one  ║"
fi
echo "╚════════════════════════════════════════════════════════════════════╝"

