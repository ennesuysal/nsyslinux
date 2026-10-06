# nsyslinux: GRUB -> vmlinuz -> initramfs -> systemd -> getty / dropbear
# Usage: make help
# All paths are relative to the directory containing this Makefile (from elsewhere: make -C ~/nsyslinux).
#
# The Makefile only contains build logic. Content files:
#   config/kernel.config   -> kernel config (in savedefconfig format)
#   config/busybox.config  -> BusyBox config
#   grub/grub.cfg          -> GRUB menu
#   overlay/               -> hand-written files copied into rootfs as-is
# To generate these files: ./ayarlari-uret.sh and ./overlay-olustur.sh
# Generated (not in git):
#   src/  rootfs/  iso/  nsyslinux.iso  .rootfs.stamp

# Recipe lines start with '>' instead of TAB (so copy-paste doesn't break them)
.RECIPEPREFIX := >

# ---- Versions (can be overridden on the command line: make KVER=7.2.9) ------
KVER   ?= 7.2.8
BBVER  ?= 1.36.1
DBVER  ?= 2025.88
JOBS   ?= $(shell nproc)

# ---- Directories (all relative) ------------------------------------------------
SRC     ?= src
ROOTFS  ?= rootfs
ISODIR  ?= iso
OVERLAY ?= overlay
CONFDIR ?= config
GRUBDIR ?= grub
ISO     ?= nsyslinux.iso
STAMP   := .rootfs.stamp

KMAJOR := $(firstword $(subst ., ,$(KVER)))
KDIR   ?= $(SRC)/linux-$(KVER)
BBDIR  ?= $(SRC)/busybox-$(BBVER)
DBDIR  ?= $(SRC)/dropbear-$(DBVER)

KURL   := https://cdn.kernel.org/pub/linux/kernel/v$(KMAJOR).x/linux-$(KVER).tar.xz
BBURL  := https://busybox.net/downloads/busybox-$(BBVER).tar.bz2
DBURL  := https://matt.ucc.asn.au/dropbear/releases/dropbear-$(DBVER).tar.bz2

# ---- systemd pieces taken from the host ---------------------------------------
SYSTEMD_DIR ?= /usr/lib/systemd
SYSTEMCTL   := $(shell command -v systemctl)
LIBMOUNT    := $(shell ldconfig -p | awk '/libmount\.so\.1 .*x86-64/ {print $$NF; exit}')

# ---- Inputs and outputs --------------------------------------------------------
KCONFIG   := $(CONFDIR)/kernel.config
BBCONFIG  := $(CONFDIR)/busybox.config
GRUBSRC   := $(GRUBDIR)/grub.cfg

VMLINUZ   := $(ISODIR)/boot/vmlinuz
INITRAMFS := $(ISODIR)/boot/initramfs.cpio.gz
GRUBCFG   := $(ISODIR)/boot/grub/grub.cfg

OVERLAY_FILES := $(shell find $(OVERLAY) -type f 2>/dev/null)
ROOTFS_FILES  := $(shell find $(ROOTFS) \( -type f -o -type d \) 2>/dev/null)

# ---- Helpers -------------------------------------------------------------------
# $(call copy_libs,binary): copies the binary's libraries (found via ldd) into rootfs
copy_libs = ldd $(1) | grep -o '/[^ ]*' | while read l; do install -D "$$l" "$(ROOTFS)$$l"; done
# $(call copy_bin,binary ...): copies each binary to the same path, along with its libraries
copy_bin  = for b in $(1); do install -D "$$b" "$(ROOTFS)$$b" && $(call copy_libs,"$$b"); done

.PHONY: all help rootfs kernel busybox dropbear systemd skel overlay initramfs iso run \
        saveconfig menuconfig clean distclean

all: iso

help:
> @echo "make             -> build everything and produce $(ISO)"
> @echo "make rootfs      -> build rootfs/ from scratch (skel + busybox + systemd + dropbear + overlay)"
> @echo "make overlay     -> only copy overlay/ into rootfs/"
> @echo "make initramfs   -> pack rootfs/"
> @echo "make kernel      -> build the kernel, copy it to $(VMLINUZ)"
> @echo "make menuconfig  -> edit the kernel config"
> @echo "make saveconfig  -> save kernel and BusyBox configs back to $(CONFDIR)/"
> @echo "make busybox     -> build BusyBox, install it into rootfs"
> @echo "make dropbear    -> build Dropbear, install it into rootfs with its libraries"
> @echo "make systemd     -> copy the host's systemd into rootfs with its libraries"
> @echo "make run         -> boot the ISO in QEMU (ssh -p 2222 root@localhost)"
> @echo "make clean       -> delete rootfs/, iso/ and the ISO"
> @echo "make distclean   -> also delete the src/ directory"

# ---- Stop explicitly if content files are missing ------------------------------
$(KCONFIG) $(BBCONFIG) $(GRUBSRC):
> @echo "ERROR: $@ not found. Create it with ./ayarlari-uret.sh."; exit 1

# ---- Source download -----------------------------------------------------------
$(SRC):
> mkdir -p $@

$(KDIR): | $(SRC)
> wget -c -O $(SRC)/linux-$(KVER).tar.xz $(KURL)
> tar -C $(SRC) -xf $(SRC)/linux-$(KVER).tar.xz

$(BBDIR): | $(SRC)
> wget -c -O $(SRC)/busybox-$(BBVER).tar.bz2 $(BBURL)
> tar -C $(SRC) -xf $(SRC)/busybox-$(BBVER).tar.bz2

$(DBDIR): | $(SRC)
> wget -c -O $(SRC)/dropbear-$(DBVER).tar.bz2 $(DBURL)
> tar -C $(SRC) -xf $(SRC)/dropbear-$(DBVER).tar.bz2

# ---- Kernel --------------------------------------------------------------------
$(KDIR)/.config: $(KCONFIG) | $(KDIR)
> cp $< $@
> $(MAKE) -C $(KDIR) olddefconfig

kernel: $(KDIR)/.config
> $(MAKE) -C $(KDIR) -j$(JOBS) bzImage
> install -D $(KDIR)/arch/x86/boot/bzImage $(VMLINUZ)

menuconfig: $(KDIR)/.config
> $(MAKE) -C $(KDIR) menuconfig

# Build vmlinuz if missing; leave it alone if present (to rebuild: make kernel)
$(VMLINUZ):
> $(MAKE) kernel

# ---- BusyBox --------------------------------------------------------------------
$(BBDIR)/.config: $(BBCONFIG) | $(BBDIR)
> cp $< $@
> yes "" | $(MAKE) -C $(BBDIR) oldconfig > /dev/null

busybox: $(BBDIR)/.config
> $(MAKE) -C $(BBDIR) -j$(JOBS)
> $(MAKE) -C $(BBDIR) CONFIG_PREFIX=$(abspath $(ROOTFS)) install

# ---- Save configs back to config/ ----------------------------------------------
saveconfig:
> @mkdir -p $(CONFDIR)
> if [ -f $(KDIR)/.config ]; then $(MAKE) -C $(KDIR) savedefconfig && cp $(KDIR)/defconfig $(KCONFIG); fi
> if [ -f $(BBDIR)/.config ]; then cp $(BBDIR)/.config $(BBCONFIG); fi

# ---- Dropbear -------------------------------------------------------------------
$(DBDIR)/dropbear: | $(DBDIR)
> cd $(DBDIR) && ./configure --disable-zlib
> $(MAKE) -C $(DBDIR) -j$(JOBS) PROGRAMS="dropbear dropbearkey"

dropbear: $(DBDIR)/dropbear
> install -D $(DBDIR)/dropbear    $(ROOTFS)/usr/sbin/dropbear
> install -D $(DBDIR)/dropbearkey $(ROOTFS)/usr/bin/dropbearkey
> $(call copy_libs,$(DBDIR)/dropbear)

# ---- systemd (from the host) ---------------------------------------------------
systemd:
> @test -x $(SYSTEMD_DIR)/systemd || { echo "$(SYSTEMD_DIR)/systemd not found (apt install systemd)"; exit 1; }
> @test -n "$(LIBMOUNT)" || { echo "libmount.so.1 not found"; exit 1; }
> $(call copy_bin,$(SYSTEMD_DIR)/systemd $(SYSTEMD_DIR)/systemd-executor $(SYSTEMCTL) $(LIBMOUNT))

# ---- rootfs ---------------------------------------------------------------------
skel:
> mkdir -p $(addprefix $(ROOTFS)/,bin sbin usr/bin usr/sbin etc proc sys dev run tmp root var/log)
> test -e $(ROOTFS)/dev/console || mknod -m 600 $(ROOTFS)/dev/console c 5 1
> ln -sfn bin/busybox $(ROOTFS)/init
> ln -sfn ../run $(ROOTFS)/var/run

overlay:
> @test -d $(OVERLAY) || { echo "ERROR: $(OVERLAY)/ missing. Create it with ./overlay-olustur.sh."; exit 1; }
> cp -a $(OVERLAY)/. $(ROOTFS)/

# Builds rootfs if it doesn't exist or if overlay/ has changed
$(STAMP): $(OVERLAY_FILES)
> $(MAKE) skel busybox systemd dropbear overlay
> touch $@

rootfs:
> rm -f $(STAMP)
> $(MAKE) $(STAMP)

# ---- initramfs ------------------------------------------------------------------
initramfs: $(INITRAMFS)

$(INITRAMFS): $(STAMP) $(ROOTFS_FILES)
> @mkdir -p $(dir $@)
> cd $(ROOTFS) && find . | cpio -o -H newc -R 0:0 --quiet | gzip -9 > $(abspath $@)

# ---- GRUB menu -----------------------------------------------------------------
$(GRUBCFG): $(GRUBSRC)
> install -D -m 644 $< $@

# ---- ISO ------------------------------------------------------------------------
iso: $(ISO)

$(ISO): $(VMLINUZ) $(INITRAMFS) $(GRUBCFG)
> grub-mkrescue -o $@ $(ISODIR)

# ---- Test -----------------------------------------------------------------------
run: $(ISO)
> qemu-system-x86_64 -m 512M -cdrom $(ISO) -boot d -nic user,model=e1000,hostfwd=tcp::2222-:22

# ---- Cleanup -------------------------------------------------------------------
clean:
> rm -rf $(ROOTFS) $(ISODIR) $(ISO) $(STAMP)

distclean: clean
> rm -rf $(SRC)
