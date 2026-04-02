# Arch Linux Installation

UEFI + LUKS2 + LVM + systemd-boot | 1TB disk, German layout, Intel CPU

---

## 1. Live Environment

German keyboard layout and time sync. The live system starts with US layout, so to type this: `z` and `y` are swapped, and `-` is on the `ß/?` key:

```
loadkeys de-latin1
timedatectl set-ntp true
```

Connect to WiFi (skip if wired):

```
iwctl
station wlan0 scan
station wlan0 get-networks
station wlan0 connect SSID
exit
```

Verify connectivity:

```
ping -c 3 archlinux.org
```

## 2. Identify Target Disk

Check which disk to install to — look at sizes to pick the right one:

```
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
```

All following commands assume `/dev/nvme0n1`. Adjust if your disk is different (e.g. `/dev/nvme0n1` with partitions `p1`, `p2`). **Don't skip this step** — `/dev/nvme0n1` might be your USB stick.

## 3. Partitioning (GPT)

2G EFI boot partition, rest for LUKS:

```
parted -s /dev/nvme0n1 mklabel gpt
parted -s /dev/nvme0n1 mkpart boot fat32 1MiB 2GiB
parted -s /dev/nvme0n1 set 1 esp on
parted -s /dev/nvme0n1 mkpart luks 2GiB 100%
lsblk /dev/nvme0n1
```

## 4. Encryption

Optional: benchmark your crypto performance. The defaults (aes-xts-plain64) are the strongest and fastest on modern CPUs with AES-NI, but you can verify here:

```
cryptsetup benchmark
```

Format with defaults (LUKS2 + argon2id + aes-xts-plain64):

```
cryptsetup luksFormat /dev/nvme0n1p2
cryptsetup luksOpen /dev/nvme0n1p2 lvm
```

If the benchmark shows a different cipher is significantly faster (e.g. `serpent-xts` on hardware without AES-NI):

```
cryptsetup luksFormat -c serpent-xts-plain64 -s 512 /dev/nvme0n1p2
```

## 5. LVM

100G root, 16G swap, rest for home:

```
pvcreate /dev/mapper/lvm
vgcreate main /dev/mapper/lvm
lvcreate -L 100GB -n root main
lvcreate -L 16GB -n swap main
lvcreate -l 100%FREE -n home main
```

## 6. Filesystems

Boot must be FAT32 for UEFI/systemd-boot:

```
mkfs.ext4 -L root /dev/mapper/main-root
mkfs.ext4 -L home /dev/mapper/main-home
mkfs.fat -F 32 -n boot /dev/nvme0n1p1
mkswap -L swap /dev/mapper/main-swap
```

## 7. Mount

```
mount /dev/mapper/main-root /mnt
mkdir /mnt/home /mnt/boot
mount /dev/mapper/main-home /mnt/home
mount /dev/nvme0n1p1 /mnt/boot
chmod 700 /mnt/boot
```

## 8. Install Base System

`intel-ucode` for Intel CPUs only — use `amd-ucode` for AMD:

```
pacstrap /mnt base linux linux-firmware base-devel vim lvm2 iwd intel-ucode
```

## 9. Fstab

```
swapon -L swap
genfstab -U -p /mnt >> /mnt/etc/fstab
```

## 10. Chroot & Configure

```
arch-chroot /mnt
```

### Locale

```
vim /etc/locale.conf
```

Content — English language, but German formats (dates, numbers, currency, paper size):

```
LANG=en_GB.UTF-8
LC_TIME=de_DE.UTF-8
LC_NUMERIC=de_DE.UTF-8
LC_MONETARY=de_DE.UTF-8
LC_PAPER=de_DE.UTF-8
LC_MEASUREMENT=de_DE.UTF-8
```

Uncomment `en_GB.UTF-8 UTF-8` and `de_DE.UTF-8 UTF-8` in `locale.gen`, then generate:

```
vim /etc/locale.gen
locale-gen
```

### Hostname

```
echo myhostname > /etc/hostname
```

### Console keymap

```
echo 'KEYMAP=de-latin1' > /etc/vconsole.conf
```

### Timezone

```
ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime
hwclock --systohc
```

### mkinitcpio

systemd-based initramfs — `sd-vconsole` loads the keymap, `sd-encrypt` handles LUKS, `microcode` replaces the separate initrd line:

Replace the `HOOKS=` line with:

```
vim /etc/mkinitcpio.conf
```

```
HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt lvm2 filesystems fsck)
```

Then build:

```
mkinitcpio -P
```

### systemd-boot

```
bootctl install
```

Loader config:

```
vim /boot/loader/loader.conf
```

Content:

```
default arch.conf
timeout 3
editor  no
```

Boot entry — pipe the UUID into the file first, then build the rest around it in vim:

```
blkid -s UUID -o value /dev/nvme0n1p2 > /boot/loader/entries/arch.conf
vim /boot/loader/entries/arch.conf
```

The file already contains the UUID. Wrap it into this structure:

```
title   Arch Linux
linux   /vmlinuz-linux
initrd  /initramfs-linux.img
options rd.luks.name=<UUID is already in the file>=lvm root=/dev/mapper/main-root rw
```

### Root password

```
passwd
```

### Enable networking

```
systemctl enable iwd
systemctl enable systemd-networkd
systemctl enable systemd-resolved
```

## 11. Cleanup & Reboot

```
exit
umount -R /mnt
swapoff -L swap
vgchange -an
cryptsetup luksClose lvm
reboot
```
