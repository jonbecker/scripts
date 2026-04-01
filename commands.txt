loadkeys de-latin1
timedatectl set-ntp true
iwctl
station wlan0 scan
station wlan0 get-networks
station wlan0 connect SSID
exit
ping -c 3 archlinux.org
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT
parted -s /dev/nvme0n1 mklabel gpt
parted -s /dev/nvme0n1 mkpart boot fat32 1MiB 2GiB
parted -s /dev/nvme0n1 set 1 esp on
parted -s /dev/nvme0n1 mkpart luks 2GiB 100%
lsblk /dev/nvme0n1
cryptsetup benchmark
cryptsetup luksFormat /dev/nvme0n1p2
cryptsetup luksOpen /dev/nvme0n1p2 lvm
pvcreate /dev/mapper/lvm
vgcreate main /dev/mapper/lvm
lvcreate -L 100GB -n root main
lvcreate -L 16GB -n swap main
lvcreate -l 100%FREE -n home main
mkfs.ext4 -L root /dev/mapper/main-root
mkfs.ext4 -L home /dev/mapper/main-home
mkfs.fat -F 32 -n boot /dev/nvme0n1p1
mkswap -L swap /dev/mapper/main-swap
mount /dev/mapper/main-root /mnt
mkdir /mnt/home /mnt/boot
mount /dev/mapper/main-home /mnt/home
mount /dev/nvme0n1p1 /mnt/boot
chmod 700 /mnt/boot
pacstrap /mnt base linux linux-firmware base-devel vim lvm2 iwd intel-ucode
swapon -L swap
genfstab -U -p /mnt >> /mnt/etc/fstab
arch-chroot /mnt
vim /etc/locale.conf
# LANG=en_GB.UTF-8
# LC_TIME=de_DE.UTF-8
# LC_NUMERIC=de_DE.UTF-8
# LC_MONETARY=de_DE.UTF-8
# LC_PAPER=de_DE.UTF-8
# LC_MEASUREMENT=de_DE.UTF-8
vim /etc/locale.gen
# uncomment: en_GB.UTF-8 UTF-8
# uncomment: de_DE.UTF-8 UTF-8
locale-gen
echo myhostname > /etc/hostname
echo 'KEYMAP=de-latin1' > /etc/vconsole.conf
ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime
hwclock --systohc
vim /etc/mkinitcpio.conf
# HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt lvm2 filesystems fsck)
mkinitcpio -P
bootctl install
vim /boot/loader/loader.conf
# default arch.conf
# timeout 3
# editor  no
blkid -s UUID -o value /dev/nvme0n1p2 > /boot/loader/entries/arch.conf
vim /boot/loader/entries/arch.conf
# title   Arch Linux
# linux   /vmlinuz-linux
# initrd  /initramfs-linux.img
# options rd.luks.name=<UUID is already in the file>=lvm root=/dev/mapper/main-root rw
passwd
systemctl enable iwd
systemctl enable systemd-networkd
systemctl enable systemd-resolved
exit
umount -R /mnt
swapoff -L swap
vgchange -an
cryptsetup luksClose lvm
reboot
