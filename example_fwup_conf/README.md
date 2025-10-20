# Example fwup Configurations for A/B/C Partition Layout

This directory contains reference implementations of fwup-common.conf files configured for A/B/C partition rotation to support zero-downtime firmware updates.

## What Changed from Standard A/B Layout

The standard Nerves A/B partition layout uses:
- 2 rootfs partitions (A and B)
- 1 application data partition

The A/B/C layout adds a third rootfs partition (C) to enable hot code reloading:
- 3 rootfs partitions (A, B, and C)
- 1 application data partition

### Key Modifications

1. **Extended Partition Structure**: Partition C and the application data are moved into an MBR extended partition to stay within the 4 primary partition limit

2. **Device Path Changes**: The application partition device path changes due to the extended partition structure:
   - BBB: `/dev/mmcblk0p4` → `/dev/mmcblk0p6` (logical partition 6)
   - RPi4: `/dev/mmcblk0p3` → `/dev/mmcblk0p5` (logical partition 5)
   - QEMU: `/dev/vda3` → `/dev/vda6` (logical partition 6)

3. **Partition Definitions**: Added offset calculations for:
   - `EXTENDED_PART_OFFSET` and `EXTENDED_PART_COUNT`
   - `ROOTFS_C_PART_OFFSET` and `ROOTFS_C_PART_COUNT`
   - Updated `APP_PART_OFFSET` for extended partition layout

4. **MBR Definitions**: Updated to define extended partition and logical partitions within it

## Platform-Specific Notes

### QEMU (qemu-fwup-common.conf)

- **Device**: `/dev/vda` (virtio block device)
- **Kernel Storage**: Separate kernel storage areas (KERNEL_A, KERNEL_B, KERNEL_C)
- **Partitions**:
  - Primary 0: Rootfs A
  - Primary 1: Rootfs B
  - Primary 3: Extended (contains C and application)
  - Logical 5: Rootfs C (`/dev/vda5`)
  - Logical 6: Application (`/dev/vda6`)

### BeagleBone Black (bbb-fwup-common.conf)

- **Device**: `/dev/mmcblk0` (eMMC/SD card)
- **Boot Partition**: Single FAT32 boot partition with multiple kernel images
- **Partitions**:
  - Primary 0: Boot partition (FAT32, contains all kernels)
  - Primary 1: Rootfs A
  - Primary 2: Rootfs B
  - Primary 3: Extended (contains C and application)
  - Logical 5: Rootfs C (`/dev/mmcblk0p5`)
  - Logical 6: Application (`/dev/mmcblk0p6`)

### Raspberry Pi 4 (rpi4-fwup-common.conf)

- **Device**: `/dev/mmcblk0` (SD card)
- **Boot Partitions**: Triple boot partitions that switch via MBR (Boot A, Boot B, and Boot C)
- **MBR Switching**: Uses three MBR definitions (mbr-a, mbr-b, and mbr-c) to switch boot partition
- **Partitions**:
  - Primary 0: Boot A, B, or C (FAT32, switched by MBR)
  - Primary 1: Rootfs A, B, or C (switched by MBR)
  - Primary 2: Rootfs C (when not active via MBR switching)
  - Primary 3: Extended (contains application only)
  - Logical 4: Application (`/dev/mmcblk0p4`)

## How to Use These Examples

1. **Fork or create a custom Nerves system** for your target hardware
2. **Copy the relevant example** to your system's `fwup_include/fwup-common.conf`
3. **Adjust partition sizes** if needed for your specific requirements
4. **Update your fwup.conf** to add the A/B/C rotation tasks (see the reference implementations in the main nerves_system_qemu_aarch64 repository)
5. **Test thoroughly** on your hardware before deploying to production

## Important Considerations

### Partition Sizes

The example configurations maintain the same rootfs partition sizes as the originals. You may want to adjust:
- Rootfs partitions if your application is larger
- Application partition size based on your data needs
- Ensure all three rootfs partitions are the same size for symmetry

### Testing

Always test the modified configuration:
1. Build a complete firmware image
2. Flash to a test device
3. Verify all partitions are created correctly (`lsblk`, `fdisk -l`)
4. Test firmware updates through the full A→B→C→A cycle
5. Test both hot reload and reboot scenarios

### Backup Your Data

Changing partition layouts will **destroy all data** on the device. Ensure you have backups before applying these changes to existing systems.

## Further Reading

- [nerves_system_qemu_aarch64](https://github.com/bigcove/nerves_system_qemu_aarch64) - Complete working reference implementation
- [Nerves Advanced Configuration](https://hexdocs.pm/nerves/advanced-configuration.html)
- [fwup Documentation](https://github.com/fwup-home/fwup)
