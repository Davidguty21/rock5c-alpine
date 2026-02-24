# Alpine Linux on Rock 5C (and Other RK3588 Boards)

A complete guide to running Alpine Linux on the Rock 5C (RK3588S) with full hardware support, including the Radxa Dual 2.5G Router HAT.

This was tested on a Rock 5C but the approach should work on any RK3588 board that runs Armbian: Rock 5B, Orange Pi 5, NanoPC-T6, etc.

## What You End Up With

- Alpine Linux 3.21 with Armbian's 6.18.x kernel (best current RK3588 support)
- 3 NICs: onboard gigabit (end0) + 2x RTL8125B 2.5GbE (eth0, eth1) via PCIe switch HAT
- NVMe storage via PCIe switch HAT (M.2 slot)
- WiFi 6 via AIC8800D80 USB adapter
- 128 packages, boots in under 10 seconds

## Why Not Just Use Armbian?

Alpine is small, fast, and gets out of your way. The base system is about 200MB. There's no systemd, no NetworkManager, no desktop environment pulling in hundreds of packages. OpenRC boots fast. apk is fast. The whole system is transparent and predictable.

The catch: Alpine doesn't support the Rock 5C natively. The RK3588 SoC needs device tree blobs, a patched u-boot, and kernel drivers that only exist in Armbian's kernel tree. So we use a hybrid approach: Armbian's boot chain and kernel, Alpine's userland.

## Overview

The setup has four parts:

1. **Base system** -- Flash Armbian, replace the rootfs with Alpine, keep the kernel
2. **PCIe switch fix** -- Kernel module to make the Radxa Router HAT work ([separate repo](https://github.com/sullrich/pcie-switch-rescan))
3. **WiFi driver** -- Build the AIC8800D80 driver from source (if you need WiFi)
4. **NVMe storage** -- Partition, format, fstab

## Part 1: Base System

### Flash Armbian to eMMC or SD Card

Download the Armbian image for Rock 5C from [armbian.com](https://www.armbian.com/rock-5c/). Flash it to your eMMC or SD card using `dd` or Balena Etcher. Boot it once to make sure it works and note the kernel version.

### Replace the Rootfs with Alpine

The idea: mount the Armbian root partition, delete the Armbian userland, and install Alpine's base system in its place, while keeping the `/boot` directory intact (kernel, DTBs, u-boot, initramfs).

From another Linux machine (or a live USB on the Rock 5C itself):

```
# Mount the Armbian root partition
mount /dev/mmcblk1p1 /mnt

# Back up the boot directory
cp -a /mnt/boot /tmp/boot-backup

# Delete everything except boot and lost+found
cd /mnt
rm -rf bin dev etc home lib media mnt opt proc root run sbin srv sys tmp usr var

# Install Alpine base system
# Download the Alpine minirootfs for aarch64:
wget https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-minirootfs-3.21.0-aarch64.tar.gz
tar xzf alpine-minirootfs-3.21.0-aarch64.tar.gz -C /mnt

# Restore boot directory (it should still be there, but just in case)
# cp -a /tmp/boot-backup/* /mnt/boot/

# Copy DNS resolution for the first boot
cp /etc/resolv.conf /mnt/etc/resolv.conf
```

### First Boot Configuration

Boot the board. You'll get a shell. Set up the basics:

```
# Set root password
passwd root

# Set hostname
echo "rock-5c" > /etc/hostname

# Set up APK repositories
cat > /etc/apk/repositories << 'EOF'
https://dl-cdn.alpinelinux.org/alpine/v3.21/main
https://dl-cdn.alpinelinux.org/alpine/v3.21/community
EOF

# Update and install essentials
apk update
apk add openssh chrony busybox-openrc openrc e2fsprogs

# Enable services
rc-update add sshd default
rc-update add chronyd default
rc-update add crond default
rc-update add networking default
rc-update add modules boot

# Set up networking (adjust for your network)
cat > /etc/network/interfaces << 'EOF'
auto lo
iface lo inet loopback

auto end0
iface end0 inet dhcp
EOF

# Set timezone
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime

# Start services
rc-service sshd start
rc-service chronyd start
rc-service networking start
```

### Install Kernel Module Build Tools

You'll need these for the PCIe switch module and WiFi driver:

```
apk add gcc make binutils musl-dev linux-headers git
```

### Keep the Armbian Kernel

Alpine's LTS kernel (6.12.x) works but has less complete RK3588 support than Armbian's 6.18.x. Stick with the Armbian kernel. The key files in `/boot`:

| File | Purpose |
|------|---------|
| `vmlinuz-6.18.8-current-rockchip64` | Kernel image |
| `initrd.img-6.18.8-current-rockchip64` | Initramfs |
| `dtb-6.18.8-current-rockchip64/` | Device tree blobs |
| `armbianEnv.txt` | Boot environment (kernel args, DTB path) |
| `boot.scr` | U-Boot boot script |

The `Image` and `uInitrd` symlinks should point to the Armbian kernel, not Alpine's.

## Part 2: PCIe Switch Fix (Radxa Router HAT)

If you're using a Radxa Dual 2.5G Router HAT or any other PCIe switch HAT, the NICs and NVMe won't show up at boot. This is a kernel-level PCIe enumeration race condition. See the [pcie-switch-rescan repo](https://github.com/sullrich/pcie-switch-rescan) for the full technical explanation.

```
git clone https://github.com/sullrich/pcie-switch-rescan.git
cd pcie-switch-rescan
./install.sh
reboot
```

After reboot you should have `eth0`, `eth1`, and `/dev/nvme0n1`.

## Part 3: WiFi (AIC8800D80)

If you have a USB WiFi adapter based on the AIC8800D80 chipset (Tenda U11, etc.), you'll need to build the driver from source. There's no mainline support.

The driver source is from the [aic8800d80 GitHub repo](https://github.com/nicman23/aic8800d80). On Alpine, you can't use the DKMS installer (it's designed for Debian/Fedora/Arch). Instead, build manually:

```
git clone https://github.com/nicman23/aic8800d80.git
cd aic8800d80

# Copy firmware
cp -r fw/aic8800D80 /lib/firmware/

# Build and install
cd drivers/aic8800
make
make install
depmod -a
```

Add the modules to `/etc/modules` so they load at boot:

```
echo "rfkill" >> /etc/modules
echo "cfg80211" >> /etc/modules
echo "aic_load_fw_usb" >> /etc/modules
echo "aic8800_fdrv_usb" >> /etc/modules
```

Configure WPA supplicant for your network:

```
apk add wpa_supplicant wireless-tools iw

cat > /etc/wpa_supplicant/wpa_supplicant.conf << 'EOF'
network={
    ssid="YourNetworkName"
    psk="YourPassword"
}
EOF

# Add WiFi to network interfaces
cat >> /etc/network/interfaces << 'EOF'

auto wlan0
iface wlan0 inet dhcp
    pre-up wpa_supplicant -B -D nl80211,wext -i wlan0 -c /etc/wpa_supplicant/wpa_supplicant.conf
    post-down killall -q wpa_supplicant
EOF
```

## Part 4: NVMe Storage

Once the PCIe switch module is working, the NVMe drive appears as `/dev/nvme0n1`. Partition and format it:

```
# Create a single partition
echo -e "o\nn\np\n1\n\n\nw" | fdisk /dev/nvme0n1

# Format as ext4
mkfs.ext4 -L nvme-data /dev/nvme0n1p1

# Mount
mkdir -p /mnt/nvme
mount /dev/nvme0n1p1 /mnt/nvme

# Add to fstab (nofail so it boots without the drive)
UUID=$(blkid -s UUID -o value /dev/nvme0n1p1)
echo "UUID=${UUID}  /mnt/nvme  ext4  defaults,nofail  0 2" >> /etc/fstab
```

## Performance (Rock 5C)

Benchmarks from the test board: Rock 5C + Radxa Dual 2.5G Router HAT + TEAMGROUP TM8FP6512G 512GB NVMe.

### NVMe (via PCIe switch, Gen3 x1)

| Test | Result |
|------|--------|
| Sequential read (1M, QD32) | 203 MB/s |
| Sequential write (1M, QD32) | 198 MB/s |
| Random 4K read (QD32) | 50,400 IOPS |
| Random 4K write (QD32) | 38,300 IOPS |
| Random 4K read (QD1, latency) | 8,283 IOPS, 115 us avg |

Sequential throughput is capped by the Gen3 x1 link through the PCIe switch. Random 4K performance is solid for a DRAM-less drive.

## Reference Configs

The `configs/` directory has reference copies of the key configuration files from a working system. These are examples, not drop-in replacements -- UUIDs, network settings, and PCIe bus addresses will differ on your hardware.

## Hardware

Tested hardware:

- [Rock 5C](https://radxa.com/products/rock5/5c) (RK3588S, 4GB RAM)
- [Radxa Dual 2.5G Router HAT](https://radxa.com/products/accessories/dual-2-5g-router-hat) (ASM2806 PCIe switch, 2x RTL8125B, M.2 NVMe slot)
- TEAMGROUP TM8FP6512G 512GB NVMe (DRAM-less)
- AIC8800D80 USB WiFi 6 adapter

Should also work on: Rock 5B, Orange Pi 5, Orange Pi 5 Plus, NanoPC-T6, and other RK3588/RK3588S boards running Armbian kernels.

## Authorship

This project was developed by Claude (Anthropic) with direction and testing by Scott Ullrich. The Alpine porting, PCIe debugging, kernel module development, and documentation were done collaboratively across multiple sessions.

## License

GPL-2.0
