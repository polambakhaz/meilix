#!/bin/bash
# build.sh -- creates an Meilix LiveCD ISO
# Author: Team
# Based on HOWTO information by Julien Lavergne <gilir@ubuntu.com>

set -eu				# Be strict

export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export LANGUAGE=en_US.UTF-8

# Script parameters: arch mirror gnomelanguage release

# Arch to build ISO for, i386 or amd64
#arch=${1:-i386}
arch=${1:-amd64}
# Ubuntu mirror to use
mirror=${2:-"http://archive.ubuntu.com/ubuntu/"}
# Ubuntu release used as a base by debootstrap.  Examples: lucid, maverick, natty.
# If you change the value here you also have to adj́ust the sources.list file 
# accordingly and check if it works with the provided lzma image.
release=${4:-xenial}
# Set of GNOME language packs to install.
# Use '\*' for all langs, 'en' for English
gnomelanguage=${3:-'{en}'}	

# Necessary data files
datafiles="image-${arch}.tar.lzma sources.list"

# Necessary development tool packages to be installed on build host
devtools="debootstrap genisoimage p7zip-full squashfs-tools ubuntu-dev-tools"

#url_wallpaper="https://meilix-generator.herokuapp.com/uploads/wallpaper" # url heroku wallpaper
#wget $url_wallpaper -P meilix-default-settings/usr/lxqt/themes/meilix/

# Make sure we have the data files we need
for i in $datafiles
do
  if [ ! -f $i ]; then
    echo "$0: ERROR: data file `pwd`/$i not found"
    exit 1
  fi
done

# Remove build fragments that are not needed during build
[ -d db ] && sudo rm -R db
[ -d pool ] && sudo rm -R pool
[ -d docs ] && sudo rm -R docs
[ -d dists ] && sudo rm -R dists
# Remove previous chroot if exists
[ -d chroot ] && sudo rm -R chroot/

# Make sure we have the tools we need installed
sudo apt-get clean
sudo apt-get update
sudo apt-get -qq install $devtools -y --no-install-recommends
sudo apt-get -qq install dpkg-dev debhelper fakeroot
sudo apt-get -qq install devscripts
sudo apt-get -qq install tree # for debugging

# Initram extraction, see https://unix.stackexchange.com/questions/163346/why-is-it-that-my-initrd-only-has-one-directory-namely-kernel
sudo apt-get -qq install binwalk
initramfs-extract() {
    local target=$1
    local offset=$(binwalk -y gzip $1 | awk '$3 ~ /gzip/ { print $1; exit }')
    shift
    dd if=$target bs=$offset skip=1 | zcat | cpio -id --no-absolute-filenames $@
}

# remove existing plymouth bootscreen packages and debuilding them again
# in the future the debuilding (=building deb packages) is to be done 
# in the meilix-artwork repo and we will fetch the latest releases of the 
# deb files here.
[ -f plymouth-meilix-logo_1.0-1_all.deb ] && rm plymouth-meilix-logo_1.0-1_all.deb
[ -f plymouth-meilix-text_1.0-1_all.deb ] && rm plymouth-meilix-text_1.0-1_all.deb
chmod +x ./scripts/debuild.sh
./scripts/debuild.sh

#Fetch the packages from meilix-artwork
wget https://github.com/fossasia/meilix-artwork/raw/deb/plymouth-theme-meilix-logo_1.0-1_all.deb -O plymouth-theme-meilix-logo_1.0-1_all.deb
wget https://github.com/fossasia/meilix-artwork/raw/deb/plymouth-theme-meilix-text_1.0-1_all.deb -O plymouth-theme-meilix-text_1.0-1_all.deb

# Create and populate the chroot using debootstrap
# Debootstrap installs a Linux in the chroot. The noisy output could be ignored
# arch, release, mirror see as set above.
sudo debootstrap --arch=${arch} ${release} chroot ${mirror} #2>&1 |grep -v "^I: "

# Use /etc/resolv.conf from the host machine during the build
sudo cp -vr /etc/resolvconf chroot/etc/resolvconf

# Copy the sources.list in chroot which enables universe / multiverse, and eventually additional repos.
# The sources.list apt ppa sources should correspond to the ${release} version 
sudo cp -v sources.list chroot/etc/apt/sources.list

# Copy our custom packages into the chroot
sudo cp -v meilix-default-settings_*_all.deb chroot
sudo cp -v systemlock_*_all.deb chroot
sudo cp -v plymouth-theme-meilix-logo_*_all.deb chroot
sudo cp -v plymouth-theme-meilix-text_*_all.deb chroot
#sudo cp -v meilix-metapackage_*_all.deb chroot
sudo cp -v ./scripts/meilix_check.sh chroot/meilix_check.sh

# Mount needed pseudo-filesystems for the chroot
sudo mount --rbind /sys chroot/sys
sudo mount --rbind /dev chroot/dev
sudo mount -t proc none chroot/proc

#Section chroot - Work *inside* the chroot
chmod +x ./scripts/chroot.sh
./scripts/chroot.sh
#Section chroot finished, continue work outside the chroot,
###############################################################
#Preparing image

# ubiquity-slideshow slides for the installer, overwrite the chroot ones
sudo cp -vr ubiquity-slideshow chroot/usr/share/

# Unmount pseudo-filesystems for the chroot
sudo umount -lfr chroot/proc
sudo umount -lfr chroot/sys
sudo umount -lfr chroot/dev

echo $0: Preparing image...

# Clean leftovers in the image directory
[ -d image ] && sudo /bin/rm -r image

# Extract a new image folder
# lzma file is a zip compressed live cd image (without squasfs content)
# it it uncompressed into a new folder "image"
#tar image-${arch}.tar.lzma
# -> taking the standard image image-${arch}.tar.lzma files does not work
#    anymore
tar xvvf amd64.tar.lzma

# Copy the kernel from the "chroot" into the "image" folder for the LiveCD
sudo \cp --verbose -rf chroot/boot/vmlinuz-**-generic image/casper/vmlinuz
sudo \cp --verbose -rf chroot/boot/initrd.img-**-generic image/casper/initrd.lz

# Extract initrd (compressed in nonuniform ways) to update casper-uuid-generic
  mkdir initrd_FILES && \
  cp image/casper/initrd.lz initrd_FILES/initrd.lz && \
  cd initrd_FILES && \
  initramfs-extract initrd.lz -v && \
  cd ..  && \
  cp initrd_FILES/conf/uuid.conf image/.disk/casper-uuid-generic && \
  rm -R initrd_FILES/
  
# Temporary SONDE - Nov 2018
set -x
cat conf/arch.conf
cat conf/uuid.conf
cat conf/initramfs.conf
cat conf/conf.d

# Fix old version and date info in .hlp files
newversion=$(date -u +%y.%m) # Should be derived from releasename $4 FIXME
for oldversion in 17.08
do
  sed -i -e "s/${oldversion}/${newversion}/g" image/isolinux/*.hlp image/isolinux/f1.txt
done
newdate=$(date -u +%Y%m%d)
for olddate in 20100113 20100928
do
  sed -i -e "s/${olddate}/${newdate}/g" image/isolinux/*.hlp image/isolinux/f1.txt
done

# Create filesystem manifests
sudo chroot chroot dpkg-query -W --showformat='${Package} ${Version}\n' >/tmp/manifest.$$
sudo cp -v /tmp/manifest.$$ image/casper/filesystem.manifest
sudo cp -v image/casper/filesystem.manifest image/casper/filesystem.manifest-desktop
rm /tmp/manifest.$$

# Remove packages from filesystem.manifest-desktop
# (language and extra for more hardware support)
REMOVE='gparted ubiquity ubiquity-frontend-gtk casper live-initramfs user-setup discover1
 xresprobe libdebian-installer4 pptp-linux ndiswrapper-utils-1.9
 ndisgtk linux-wlan-ng libatm1 setserial b43-fwcutter uterm
 linux-headers-generic indicator-session indicator-application' 
for i in $REMOVE
do
    sudo sed -i "/${i}/d" image/casper/filesystem.manifest-desktop
done

# Now squash the live filesystem
echo "$0: Starting mksquashfs at $(date -u) ..."
sudo mksquashfs chroot image/casper/filesystem.squashfs -noappend -no-progress
echo "$0: Finished mksquashfs at $(date -u )"

# Generate md5sum.txt checksum file
cd image && sudo find . -type f -print0 |xargs -0 sudo md5sum |grep -v "\./md5sum.txt" >md5sum.txt

# Generate a small temporary ISO so we get an updated boot.cat
IMAGE_NAME=${IMAGE_NAME:-"Meilix ${release} $(date -u +%Y%m%d) - ${arch}"}
ISOFILE=meilix-${release}-$(date -u +%Y%m%d)-${arch}.iso
#sudo mkisofs -r -V "$IMAGE_NAME" -cache-inodes -J -l \
sudo genisoimage -r -V "$IMAGE_NAME" -cache-inodes -J -l \
  -b isolinux/isolinux.bin -c isolinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  --publisher "Meilix Packaging Team" \
  --volset "Meilix Linux http://www.meilix.org" \
  -p "${DEBFULLNAME:-$USER} <${DEBEMAIL:-on host $(hostname --fqdn)}>" \
  -A "$IMAGE_NAME" \
  -m filesystem.squashfs \
  -o ../$ISOFILE.tmp .

# Mount the temporary ISO and copy boot.cat out of it
tempmount=/tmp/$0.tempmount.$$
mkdir $tempmount
loopdev=$(sudo losetup -f)
sudo losetup $loopdev ../$ISOFILE.tmp
sudo mount -r -t iso9660 $loopdev $tempmount
sudo cp -vp $tempmount/isolinux/boot.cat isolinux/
sudo umount $loopdev
sudo losetup -d $loopdev
rmdir $tempmount

# Generate md5sum.txt checksum file (now with new improved boot.cat)
sudo find . -type f -print0 |xargs -0 sudo md5sum |grep -v "\./md5sum.txt" >md5sum.txt

# Remove temprary ISO file
sudo rm ../$ISOFILE.tmp

# Create an Meilix ISO from the image directory tree
# sudo mkisofs -r -V "$IMAGE_NAME" -cache-inodes -J -l \
sudo genisoimage -r -V "$IMAGE_NAME" -cache-inodes -J -l \
  -allow-limited-size -udf \
  -b isolinux/isolinux.bin -c isolinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  --publisher "Meilix Packaging Team" \
  --volset "Meilix Linux" \
  -p "${DEBFULLNAME:-$USER} <${DEBEMAIL:-on host $(hostname --fqdn)}>" \
  -A "$IMAGE_NAME" \
  -o ../$ISOFILE .

# Fix up ownership and permissions on newly created ISO file
# On Travis $USER is travis.
sudo chown $USER:$USER ../$ISOFILE
chmod 0444 ../$ISOFILE

# Create the associated md5sum file
cd ..
md5sum $ISOFILE >${ISOFILE}.md5

#Show how much space the build process uses *fun*
du -hs .

# see travis confguration for the deployment that follows in case of a Travis build. 
