#!/bin/bash

ARCH=$1

if [ "$ARCH" != "i386" -a "$ARCH" != "amd64" ]
then
    echo "Usage: $0 [i386|amd64]"
    exit 1
fi

# If we do a normal installation, without using LVM, cryptsetup or RAID, we should
# avoid deleting the following packages
MANDATORY_PACKAGES="
crda
grub
installation-report
linux-firmware
lvm
os-prober
dmsetup
devmapper
crypt
generic-pae
mdadm
kpartx
multipath
raid
lilo
xfs
jfs
usbutils
watershed
wireless"

CHROOT_INSTALLED_PACKAGES=$(sudo chroot ubuntu-precise-$ARCH/ dpkg -l|awk '{ print $2 }'|tail -n +6)

PACKAGES_TO_INSTALL=$(cat data/extra-packages.list | xargs)
if [ "$ARCH" == "amd64" ]
then
    PACKAGES_TO_INSTALL=$(echo $PACKAGES_TO_INSTALL | sed 's/generic-pae/generic/g')
    MANDATORY_PACKAGES=$(echo $MANDATORY_PACKAGES | sed 's/generic-pae/generic/')
fi

CHROOT_ZENTYAL_PACKAGES=$(sudo chroot ubuntu-precise-$ARCH/ apt-get install --simulate --no-install-recommends -y --force-yes $PACKAGES_TO_INSTALL |grep ^Inst|awk '{ print $2 }')

echo $CHROOT_INSTALLED_PACKAGES $CHROOT_ZENTYAL_PACKAGES | tr ' ' "\n" > NO_DELETE

for pkgfile in `find cd-image-$ARCH/pool/main -name "*.deb"`
do
    name=$(basename $pkgfile | cut -f1 -d_)
    if grep -q ^$name$ NO_DELETE
    then
        continue
    fi

    mandatory=0
    for p in $MANDATORY_PACKAGES
    do
        if echo $name | grep -q $p
        then
            mandatory=1
            break
        fi
    done

    if [ $mandatory -eq 0 ]
    then
        echo $pkgfile
    fi
done

find cd-image-$ARCH/pool/main -depth -type d -empty -exec echo {} \;

rm -f NO_DELETE

