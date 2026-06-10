#!/usr/bin/env bash
# NVMe Clone Script - Version 0.4.0
# Fedora 44 Compatible NVMe Cloning Tool

# Ensure this script is run with bash, not sh
if [[ -z "$BASH_VERSION" ]]; then
    echo "Error: This script requires bash, not sh."
    echo ""
    echo "Please run with one of these commands:"
    echo "  bash clone_nvme.sh"
    echo "  ./clone_nvme.sh"
    echo "  sudo bash clone_nvme.sh"
    echo ""
    echo "Do NOT use: sudo sh clone_nvme.sh"
    exit 1
fi

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
    local partclone_available=false
    
    # Check for required commands
    for cmd in lsblk dd partprobe btrfs uuidgen awk grep; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_tools+=("$cmd")
        fi
    done
    
    # Check for partclone (optional but highly recommended)
    # Try multiple ways to locate it in case it's not in the standard PATH
    if command -v partclone.auto &> /dev/null; then
        partclone_available=true
    elif command -v partclone &> /dev/null; then
        partclone_available=true
    elif [[ -x /usr/bin/partclone.auto ]] || [[ -x /usr/sbin/partclone.auto ]]; then
        partclone_available=true
    elif [[ -x /usr/bin/partclone ]] || [[ -x /usr/sbin/partclone ]]; then
        partclone_available=true
    elif sudo -n which partclone.auto &> /dev/null 2>&1; then
        partclone_available=true
    elif sudo -n which partclone &> /dev/null 2>&1; then
        partclone_available=true
    fi
    
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
    
    # Warn user if partclone is missing and explain the benefit
    if [[ "$partclone_available" == false ]]; then
        echo ""
        echo "╔════════════════════════════════════════════════════════════════╗"
        echo "║  ⚠️  RECOMMENDED: Install partclone for MUCH faster cloning     ║"
        echo "╚════════════════════════════════════════════════════════════════╝"
        echo ""
        echo "Cloning speed comparison:"
        echo "  • WITH partclone:    Copies only used space (1-2 TB = ~10-30 min)"
        echo "  • WITHOUT partclone: Copies entire drive (1-2 TB = ~30-90 min)"
        echo ""
        echo "To install partclone on Fedora 44:"
        echo "  sudo dnf install partclone"
        echo ""
        echo "To verify installation, run:"
        echo "  which partclone.auto"
        echo "  which partclone"
        echo ""
        read -p "Continue without partclone? (y/N): " proceed
        if [[ "$proceed" != "y" && "$proceed" != "Y" ]]; then
            echo "Exiting. Please install partclone and try again."
            exit 1
        fi
        echo ""
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
            echo "╔════════════════════════════════════════════════════════════════════╗"
            echo "║  NVMe Clone Script - Version 0.4.0 (Fedora 44 Compatible)          ║"
            echo "╚════════════════════════════════════════════════════════════════════╝"
            echo ""
            echo "⚠️  IMPORTANT: This script MUST be run with BASH, not sh!"
            echo ""
            echo "CORRECT ways to run:"
            echo "  bash clone_nvme.sh"
            echo "  bash clone_nvme.sh --dry-run"
            echo "  sudo bash clone_nvme.sh"
            echo "  ./clone_nvme.sh (with execute permissions)"
            echo ""
            echo "WRONG - Do NOT use:"
            echo "  ✗ sh clone_nvme.sh"
            echo "  ✗ sudo sh clone_nvme.sh"
            echo ""
            echo "OPTIONS:"
            echo "  --dry-run     Show what would happen without making any changes"
            echo "  --help        Display this help message"
            echo ""
            echo "REQUIREMENTS (REQUIRED):"
            echo "  - Bash 4.0+ (NOT sh/dash)"
            echo "  - sudo access (or run as root)"
            echo "  - BTRFS tools (btrfs-progs)"
            echo "  - util-linux (lsblk, partprobe, mount)"
            echo ""
            echo "RECOMMENDED (for 3-9x faster cloning):"
            echo "  - partclone: Only copies used space instead of entire drive"
            echo "    Install with: sudo dnf install partclone"
            echo ""
            echo "DESCRIPTION:"
            echo "  This script clones one NVMe drive to another, including:"
            echo "  - Copying all data and partition layout"
            echo "  - Auto-detecting BTRFS filesystems"
            echo "  - Updating filesystem UUIDs to avoid conflicts"
            echo "  - Resizing the filesystem to fill the destination drive"
            echo ""
            echo "USAGE:"
            echo "  1. Preview with: bash clone_nvme.sh --dry-run"
            echo "  2. Run with:     bash clone_nvme.sh"
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

# --- SMART CLONING FUNCTION ---
# Uses partclone for efficient cloning (only copies used space)
# Falls back to dd if partclone is not available

clone_disk() {
    local source="$1"
    local destination="$2"
    
    # Detect if partclone is available (using robust methods)
    local use_partclone=false
    local partclone_cmd=""
    
    # Try to find partclone command
    if command -v partclone.auto &> /dev/null; then
        use_partclone=true
        partclone_cmd="partclone.auto"
    elif command -v partclone &> /dev/null; then
        use_partclone=true
        partclone_cmd="partclone"
    elif [[ -x /usr/bin/partclone.auto ]]; then
        use_partclone=true
        partclone_cmd="/usr/bin/partclone.auto"
    elif [[ -x /usr/sbin/partclone.auto ]]; then
        use_partclone=true
        partclone_cmd="/usr/sbin/partclone.auto"
    elif [[ -x /usr/bin/partclone ]]; then
        use_partclone=true
        partclone_cmd="/usr/bin/partclone"
    elif [[ -x /usr/sbin/partclone ]]; then
        use_partclone=true
        partclone_cmd="/usr/sbin/partclone"
    fi
    
    if [[ "$use_partclone" == true ]]; then
        local clone_method="partclone (fast - only copies used space)"
    else
        local clone_method="dd (slow - copies every byte)"
    fi
    
    echo "Cloning method: $clone_method"
    echo ""
    
    if [[ "$use_partclone" == true ]]; then
        # Use partclone for fast cloning
        echo "Step 2a: Copying partition table..."
        if [[ "$DRY_RUN" == false ]]; then
            # Copy just the MBR/GPT (first 1MB is usually safe)
            sudo dd if="$source" of="$destination" bs=512 count=2048 2>/dev/null
        fi
        
        echo "Step 2b: Cloning partitions with partclone (fast)..."
        echo "         Using: $partclone_cmd"
        echo "         Only copying used space - this will be much faster!"
        echo ""
        
        if [[ "$DRY_RUN" == false ]]; then
            # Get list of partitions
            local partitions=$(sudo lsblk -np "$source" | grep -E "^${source}p[0-9]" | awk '{print $1}')
            
            local part_num=1
            for src_part in $partitions; do
                dst_part="${destination}p${part_num}"
                
                echo "  Cloning $src_part to $dst_part..."
                
                # Use partclone to clone only used space
                if ! sudo "$partclone_cmd" -s "$src_part" -o "$dst_part" -N -L -L 2>/dev/null; then
                    # Fallback to dd if partclone fails for this partition
                    echo "  Partclone failed for $src_part, falling back to dd..."
                    sudo dd if="$src_part" of="$dst_part" bs=4M status=progress conv=fsync
                fi
                
                part_num=$((part_num + 1))
            done
        fi
    else
        # Use dd for cloning (slower but always available)
        echo "Step 2: Cloning with dd (this will copy every byte)..."
        echo ""
        
        if [[ "$DRY_RUN" == false ]]; then
            sudo dd if="$source" of="$destination" bs=4M status=progress conv=fsync
        fi
    fi
}

# --- INTERACTIVE DEVICE SELECTION ---

# Function to list available NVMe devices
list_nvme_devices() {
    lsblk -d -n -o NAME,SIZE,SERIAL | grep "^nvme" | sort
}

# Function to display numbered list of available devices
display_devices_numbered() {
    local count=1
    while IFS= read -r line; do
        echo "  [$count] $line"
        count=$((count + 1))
    done < <(list_nvme_devices)
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
        echo "Error: No available NVMe devices found." >&2
        exit 1
    fi
    
    echo "" >&2
    echo "===============================================" >&2
    echo "$prompt" >&2
    echo "===============================================" >&2
    echo "" >&2
    
    # Show numbered list of devices
    local count=1
    for info in "${device_info[@]}"; do
        echo "[$count] $info" >&2
        count=$((count + 1))
    done
    echo "" >&2
    
    local choice
    while true; do
        read -p "Enter your selection (1-${#devices[@]}): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#devices[@]} )); then
            # Output ONLY the device path to stdout for capture
            echo "/dev/${devices[$((choice - 1))]}"
            return
        else
            echo "Invalid selection. Please try again (enter a number between 1 and ${#devices[@]})." >&2
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
display_devices_numbered
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
if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] Would detect and use fastest available cloning method"
    echo "[DRY-RUN] Preferred: partclone (only copies used space)"
    echo "[DRY-RUN] Fallback: dd (copies every byte)"
    echo "[DRY-RUN] This copies all partitions, filesystems, and data from source to destination"
else
    clone_disk "$SRC" "$DST"
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

