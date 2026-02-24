#!/bin/sh
echo "=== Setting up Alpine kernel with matching modules ==="

# Install Alpine kernel (already installed, just regenerate initramfs)
apk add linux-lts mkinitfs

# Generate initramfs
mkinitfs -o /boot/initramfs-lts 6.12.67-0-lts

# Update boot links
cd /boot
rm -f Image uInitrd
ln -sf vmlinuz-lts Image
ln -sf dtbs-lts dtb

# Create uInitrd from initramfs
mkimage -A arm64 -T ramdisk -C none -n "Alpine initramfs" -d initramfs-lts uInitrd 2>/dev/null || \
  cp initramfs-lts uInitrd

echo "Kernel setup complete. Reboot to use Alpine kernel."
