[![Build ISO](https://github.com/ennesuysal/nsyslinux/actions/workflows/build.yml/badge.svg)](https://github.com/ennesuysal/nsyslinux/actions/workflows/build.yml)

# nsyslinux

A minimal x86_64 Linux distribution built from scratch with a single Makefile: a kernel from
kernel.org, BusyBox userland, systemd as init, Dropbear for SSH and Docker. The result is a
bootable ISO that runs entirely from RAM and can install itself to a hard disk.

```
GRUB -> vmlinuz -> initramfs -> systemd -> getty / dropbear / docker
```

## Requirements

The build runs on an **x86_64 Debian/Ubuntu host**. systemd, iptables, the disk tools and GRUB are
copied from the host together with their libraries, so the host's versions end up in the image.

```sh
sudo apt-get install build-essential bc bison flex libelf-dev libssl-dev \
    wget xz-utils bzip2 cpio grub-common grub-pc-bin grub2-common xorriso mtools \
    systemd iptables ca-certificates fdisk e2fsprogs
# for testing
sudo apt-get install qemu-system-x86 qemu-utils
```

Building the rootfs needs root (it creates `/dev/console` with `mknod`).

## Building

```sh
make kernel      # first time only; takes a while
sudo make        # -> nsyslinux.iso
```

Sources are downloaded into `src/`. Versions can be overridden on the command line, for example
`make KVER=7.2.9`.

| Target | What it does |
|---|---|
| `make` | Build everything and produce `nsyslinux.iso` |
| `make kernel` | Build the kernel. `vmlinuz` is not rebuilt on its own, so run this after changing `config/kernel.config` |
| `make rootfs` | Rebuild `rootfs/` (BusyBox, systemd, Dropbear, iptables, Docker, installer tools, overlay) |
| `make menuconfig` | Edit the kernel config |
| `make saveconfig` | Save the kernel and BusyBox configs back to `config/` |
| `make run` | Boot the ISO in QEMU |
| `make run-install` | Boot the ISO in QEMU with an empty `disk.qcow2` attached, to test the installer |
| `make run-disk` | Boot the system installed on `disk.qcow2` |
| `make clean` | Delete `rootfs/`, `iso/` and the ISO (`make distclean` also deletes `src/`) |

`make rootfs` does not remove files that were deleted from `overlay/`. Run `make clean` after
removing anything.

## Running

`make run` starts QEMU with 2 GB of RAM and forwards port 2222 to the guest's SSH port:

```sh
ssh -p 2222 root@localhost
```

The GRUB menu has two entries:

- **nsyslinux**: the live system, running from RAM. Changes are lost on reboot.
- **nsyslinux: install to hard disk**: the installer.

Log in as `root`. The password hash is in `overlay/etc/passwd`. To set your own password, generate a
hash with `openssl passwd -1` and put it there.

tty2 (Alt+F2) has an emergency shell (`sulogin`). It asks for the root password too, but unlike
the tty1 login it also works while `/` is still read-only, for example after a failed boot fsck.

Anyone at the console can still edit the kernel command line in the GRUB menu (for example
`init=/bin/sh`) and get a shell without a password; the GRUB menu has no password.

## Installing to a hard disk

Choose **install to hard disk** in the GRUB menu. The installer lists the disks it finds, asks you to pick one and to type
`yes`, then:

1. Writes an MBR partition table with one bootable partition. **Everything on the disk is lost.**
2. Formats the partition as ext4 and copies the live system onto it.
3. Writes `/etc/fstab` and installs GRUB into the MBR.

The installed system boots without an initramfs. The kernel finds the root partition by
`root=PARTUUID=…` and mounts it read-only. `diskler.service` then runs `fsck` on everything in
`/etc/fstab`, remounts `/` read-write and mounts the rest. To add a disk, get its UUID with `blkid`
and add a line:

```
UUID=<uuid>  /data  ext4  defaults,nofail  0  2
```

If the installer finds no disks, it lists the machine's storage controllers and whether a driver is
bound to them. A controller with `driver: NONE` needs a driver enabled in `config/kernel.config`.

## What's in the image

| Unit | Purpose |
|---|---|
| `diskler.service` | fsck and mount `/etc/fstab` (disk installs only) |
| `ag.service` | Network: `eth0` via DHCP (BusyBox `udhcpc`) |
| `sshd.service` | Dropbear on port 22. The host key is generated on the first connection |
| `docker.service` | Docker daemon. Logs to `/var/log/docker.log` |
| `getty-tty1.service` | Login prompt on tty1 |
| `acil-kabuk.service` | Emergency shell on tty2 (asks for the root password) |
| `merhaba.service` | Boot greeting on the console |

There is no udev, journald or D-Bus. Units use `DefaultDependencies=no` and are started directly by
`default.target`.

### Docker

Docker comes from the official static binaries (`DKVER` in the Makefile). Bridge networking and
`-p` port publishing work through the host's `iptables-nft`. The daemon uses the `cgroupfs` cgroup
driver because there is no D-Bus. On the live system everything, including pulled images, lives in
RAM.

```sh
docker run --rm hello-world
```

## Customizing

- **Kernel**: edit `config/kernel.config` (savedefconfig format) or use `make menuconfig` and
  `make saveconfig`. The build fails if `olddefconfig` silently drops an option you set to `=y`
  because its dependencies aren't met, and lists the dropped options. Everything must be built in
  (`=y`): kernel modules are not installed.
- **BusyBox**: edit `config/busybox.config`.
- **Files in the image**: anything under `overlay/` is copied into the root file system as is.
  Scripts need the executable bit in git (`git update-index --chmod=+x <file>`). The
  `overlay` target also sets it explicitly for the scripts that need it, because Windows checkouts
  lose it.
- **Line endings**: `.gitattributes` forces LF, so files checked out on Windows still work on Linux.

## Repository layout

```
Makefile                 build logic
config/kernel.config     kernel config (savedefconfig format)
config/busybox.config    BusyBox config
grub/grub.cfg            GRUB menu of the ISO
overlay/                 files copied into the root file system
  etc/systemd/system/    systemd units
  usr/sbin/nsys-install  disk installer
  usr/sbin/nsys-mount    boot-time fsck and fstab mounting
.github/workflows/       CI
```

## CI

`.github/workflows/build.yml` builds the ISO only when a `v*` tag is pushed, and publishes it with
its SHA-256 checksum as a GitHub release.

Pushes to `main` don't build an ISO. They build the kernel, BusyBox and Dropbear, download Docker,
and save them as caches. A tag run can only use caches from `main` (not from earlier tags), so
release builds reuse them and skip the kernel build. To get a fast release, push the tag after the
`main` run for that commit has finished.

## Known limitations

- **BIOS boot only.** The ISO and installed disks boot with legacy BIOS (MBR). UEFI-only machines
  are not supported.
- **No clean shutdown.** BusyBox's `reboot`/`poweroff` don't work under systemd, and systemd's own
  shutdown pieces aren't included. Use `reboot -f` / `poweroff -f`. File systems are not unmounted.
  The boot-time fsck catches any damage from that.
- **Host-dependent.** systemd and the other copied tools come from the build host, so the image
  changes when the host is upgraded. CI pins `ubuntu-24.04` for this reason.
