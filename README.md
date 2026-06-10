# NVMe Cloning Script

This project provides an interactive script to clone one NVMe drive to another.
It has been tested on a Fedora 44 Workstation Live Image

## ⚠️ IMPORTANT: Use Bash, Not sh

**This script MUST be run with `bash`, NOT `sh` or `dash`.**

### Correct ways to run:
```bash
bash clone_nvme.sh
bash clone_nvme.sh --dry-run
sudo bash clone_nvme.sh
./clone_nvme.sh              # if executable
```

### WRONG - Do NOT use:
```bash
✗ sh clone_nvme.sh
✗ sudo sh clone_nvme.sh
```

If you accidentally run it with `sh`, you'll get an error message with instructions.

## Overview

`clone_nvme.sh` safely clones the entire contents of one NVMe drive to another, including partition tables, boot data, and filesystem data. It also handles UUID regeneration and BTRFS filesystem resizing to prevent conflicts when both drives are connected simultaneously.

## Requirements

- **Sudo/Root Access**: **YES - REQUIRED**. This script performs privileged operations including:
  - Unmounting filesystems
  - Reading/writing directly to disk devices
  - Modifying filesystem UUIDs
  - Resizing filesystems
  
  You must run this script with `sudo` or have root privileges.

- **NVMe Devices**: At least 2 NVMe drives connected to the system
- **BTRFS Filesystem**: The script is optimized for BTRFS filesystems (particularly Fedora installations)
- **Available Tools**: `lsblk`, `dd`, `uuidgen`, `partprobe`, `btrfs`

### Recommended (for faster cloning):

- **partclone**: Dramatically speeds up cloning by only copying used space instead of the entire drive
  - Install with: `sudo dnf install partclone`
  - **Speed improvement**: 3-9x faster for typical clones
  - Without it, the script falls back to `dd` (which is slower but always available)

## Usage

### Running the Script

⚠️ **IMPORTANT**: Always use `bash`, not `sh`!

```bash
# Preview what will happen (safe, no changes made)
bash clone_nvme.sh --dry-run

# Run the actual clone operation
bash clone_nvme.sh

# Or with sudo if needed for password-less sudo
sudo bash clone_nvme.sh
```

### Get Help

```bash
bash clone_nvme.sh --help
```

1. The script displays all available NVMe devices with their sizes and serial numbers
2. You select the **source device** (device to clone FROM)
3. You select the **destination device** (device to clone TO)
   - The source device is automatically excluded from the destination options to prevent accidental selection
4. You confirm the clone operation (the script shows what will happen)

### Interactive Workflow

```
=== AVAILABLE NVMe DEVICES ===
nvme0n1     1.8T
nvme1n1     3.7T

Select SOURCE device to clone FROM:
============================================
1) nvme0n1     1.8T
2) nvme1n1     3.7T

Enter your selection (1-2): 1

Select DESTINATION device to clone TO:
============================================
1) nvme1n1     3.7T

Enter your selection (1-1): 1

=== CLONE CONFIGURATION ===
Source:      /dev/nvme0n1
Destination: /dev/nvme1n1

=== WARNING ===
This will irreversibly overwrite all data on /dev/nvme1n1
Are you sure you want to proceed? (y/N): y

[Cloning begins...]
```

## What the Script Does

1. **Device Selection**: Interactive menu to choose source and destination NVMe drives
2. **Unmounting**: Safely unmounts any partitions on source and destination drives
3. **Cloning**: Uses `dd` to copy the exact partition table and raw data (with progress display)
4. **Partition Table Update**: Informs the kernel of the new partition layout
5. **UUID Regeneration**: Creates new UUIDs for the BTRFS filesystem to prevent conflicts
6. **Filesystem Mounting**: Mounts the cloned filesystem for resizing
7. **Filesystem Resize**: Expands the BTRFS filesystem to use 100% of the destination drive's capacity
8. **Cleanup**: Unmounts the temporary filesystem

## Important Notes

⚠️ **WARNING**: This script will **irreversibly overwrite** all data on the destination drive. Triple-check your device selection before confirming!

- **Verification**: Use `lsblk` before running the script to verify your device names and capacities
- **Time**: Cloning takes time proportional to the drive size and data present. A 1TB drive may take 30+ minutes
- **Connection**: Both drives must remain connected throughout the entire process
- **Power**: Do not power off the system during cloning (it will corrupt the destination drive)
- **BTRFS Specific**: The script assumes your root filesystem is on partition 3 and uses BTRFS. Adjust accordingly if your setup differs

## Troubleshooting

- **"No available NVMe devices found"**: No NVMe drives detected. Verify drives are properly connected.
- **Permission denied**: You must run with `sudo`
- **Mount point already in use**: Ensure the destination drive is not already mounted
- **UUID conflicts**: If you see UUID-related errors, the script handles this automatically

## Example Scenarios

### Scenario: Upgrading from 1TB to 4TB
```bash
# Source: nvme0n1 (1TB with existing Fedora installation)
# Destination: nvme1n1 (4TB empty drive)

sudo ./clone_nvme.sh
# Select nvme0n1 as source
# Select nvme1n1 as destination
# Confirm the operation
# After completion, shut down and boot from the 4TB drive
```

## Post-Clone Steps

1. Shut down the system
2. Remove the old drive (if desired)
3. Boot from the newly cloned drive
4. Verify all data and partitions are present
5. Run filesystem checks if needed: `sudo btrfs filesystem show`
