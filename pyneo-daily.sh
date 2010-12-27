#!/bin/sh -e

# use apt-cacher
# use 2.5G tmpfs
# mount -t tmpfs -o size=2500M tmpfs /tmp/ramdisk

PWD="`pwd`"
SRC_DIR="$PWD/src"
DEB_DIR="$PWD/debian"
REPO_DIR="$PWD/repo"
POOL_DIR="$REPO_DIR/pool"
QEMUCONF="$PWD/qemuconfig"
BASE="$PWD/base"
BUILD="$PWD/build"
DATENOW="`date -u +%Y%m%d`"
DEBMIRROR="http://localhost:3142/ftp.de.debian.org/debian"
DIST=sid
HOSTARCH="`dpkg --print-architecture`"
MAINTAINER=1

mkdir -p "$SRC_DIR"
mkdir -p "$REPO_DIR"
mkdir -p "$BUILD"
mkdir -p "$BASE"
rm -rf "$SRC_DIR/"*
rm -rf "$REPO_DIR/"*
rm -rf "$BUILD/"*

#############################################################################
#                            common functions                               #
#############################################################################

create_cow()
{
	if [ ! -d "$BASE/$1.cow" ]; then
		cowbuilder --create --distribution $DIST --basepath "$BASE/$1.cow" \
			--architecture $1 --buildplace $BUILD \
			--buildresult $POOL_DIR --mirror $DEBMIRROR \
			--aptcache ""
	fi
}

build_cow()
{
	cowbuilder --build "$2" --basepath "$BASE/$1.cow" --buildplace $BUILD \
		--buildresult $POOL_DIR --mirror $DEBMIRROR --aptcache ""
}

# qemubuilder config has to be created dynamically because BASEPATH needs to
# be absolute
create_qemu()
{
	if [ ! -f "$BASE/$1.qemu" ]; then
		cat > "$BASE/$1.conf" << __EOF__
ARCH=$1
MEMORY_MEGS=256
BASEPATH=$BASE/$1.qemu
MIRRORSITE=$DEBMIRROR
BUILDPLACE=$BUILD
BUILDRESULT=$POOL_DIR
ARCH_DISKDEVICE=sd
DISTRIBUTION=$DIST
__EOF__
		case "$1" in
			"i386")
				echo "KERNEL_IMAGE=$QEMUCONF/i386/vmlinuz-2.6.32-5-686" >> "$BASE/$1.conf"
				echo "INITRD=$QEMUCONF/i386/initrd.img-2.6.32-5-686" >> "$BASE/$1.conf"
				;;
			"amd64")
				echo "KERNEL_IMAGE=$QEMUCONF/amd64/vmlinuz-2.6.32-5-amd64" >> "$BASE/$1.conf"
				echo "INITRD=$QEMUCONF/amd64/initrd.img-2.6.32-5-amd64" >> "$BASE/$1.conf"
				;;
			"armel")
				echo "KERNEL_IMAGE=$QEMUCONF/armel/zImage-2.6.29.4" >> "$BASE/$1.conf"
				;;
			"mipsel")
				echo "KERNEL_IMAGE=$QEMUCONF/mipsel/vmlinux-2.6.32-5-4kc-malta" >> "$BASE/$1.conf"
				;;
		esac
		qemubuilder --configfile "$BASE/$1.conf" --create
	fi
}

build_qemu()
{
	qemubuilder --build "$2" --configfile "$BASE/$1.conf"
}

#############################################################################
#                        create qemubuilder base                            #
#############################################################################

case "$HOSTARCH" in
	"i386")
		create_cow i386
		create_qemu amd64
		create_qemu armel
		create_qemu mipsel
		;;
	"amd64")
		create_cow i386
		create_cow amd64
		create_qemu armel
		create_qemu mipsel
		;;
	"armel")
		create_qemu i386
		create_qemu amd64
		create_cow armel
		create_qemu mipsel
		;;
	"mipsel")
		create_qemu i386
		create_qemu amd64
		create_qemu armel
		create_cow mipsel
		;;
	*)
		echo "unknown host architecture: $HOSTARCH"
		exit 1
		;;
esac

#############################################################################
#                          build source packages                            #
#############################################################################

curl http://git.pyneo.org/browse/cgit/pyneo/snapshot/pyneo-HEAD.tar.gz | tar xz
for src in gsm0710muxd pyneo-pybankd pyneo-pyneod pyneo-resolvconf python-pyneo zad; do # add pyneo-pygsmd?
	cp -r "pyneo-HEAD/$src" "$SRC_DIR/$src"
done
rm -rf pyneo-HEAD

for repo in pyneo-zadthemes pyneo-zadosk pyneo-zadwm python-ijon; do
	curl http://git.pyneo.org/browse/cgit/$repo/snapshot/$repo-HEAD.tar.gz | tar xz
	mv "$repo-HEAD" "$SRC_DIR/$repo"
done

for pkg in "$SRC_DIR/"*; do
	PKG="${pkg##*/}" # emulate basename(1)
	mv "$SRC_DIR/$PKG" "$SRC_DIR/$PKG-$DATENOW"
	tar --directory "$SRC_DIR" --create --gzip --file "$SRC_DIR/${PKG}_$DATENOW.orig.tar.gz" "$PKG-$DATENOW"
	cp -r "$DEB_DIR/$PKG" "$SRC_DIR/$PKG-$DATENOW/debian"
	DEBEMAIL="josch@pyneo.org" DEBFULLNAME="Johannes Schauer" dch --package "$PKG" --newversion "$DATENOW-$MAINTAINER" \
		--distribution unstable --empty --changelog "$SRC_DIR/$PKG-$DATENOW/debian/changelog" --create "new nightly build"
	cd "$SRC_DIR/$PKG-$DATENOW"
	dpkg-buildpackage -S -us -uc
	cd "../../"
done

mkdir -p "$POOL_DIR"
mv "$SRC_DIR/"*_* "$POOL_DIR"

#############################################################################
#                         build binary packages                             #
#############################################################################

for dsc in "$POOL_DIR/"*.dsc; do
	if grep "^Architecture: all$" "$dsc" > /dev/null; then
		# build native
		build_cow $HOSTARCH "$dsc"
	else
		# build for each arch
		case "$HOSTARCH" in
			"i386")
				build_cow i386 "$dsc"
				build_qemu amd64 "$dsc"
				build_qemu armel "$dsc"
				build_qemu mipsel "$dsc"
				;;
			"amd64")
				build_cow i386 "$dsc"
				build_cow amd64 "$dsc"
				build_qemu armel "$dsc"
				build_qemu mipsel "$dsc"
				;;
			"armel")
				build_qemu i386 "$dsc"
				build_qemu amd64 "$dsc"
				build_cow armel "$dsc"
				build_qemu mipsel "$dsc"
				;;
			"mipsel")
				build_qemu i386 "$dsc"
				build_qemu amd64 "$dsc"
				build_qemu armel "$dsc"
				build_cow mipsel "$dsc"
				;;
			*)
				echo "unknown host architecture: $HOSTARCH"
				exit 1
				;;
		esac
	fi
done

#############################################################################
#                           create repository                               #
#############################################################################

for arch in i386 amd64 armel mipsel; do
	mkdir -p "$REPO_DIR/dists/unstable/main/binary-$arch"
	cat > "$REPO_DIR/dists/unstable/main/binary-$arch/Release" << __EOF__
Archive: unstable
Component: main
Origin: Debian
Label: Debian
Architecture: $arch
__EOF__
done

mkdir -p "$REPO_DIR/dists/unstable/main/source"
cat > "$REPO_DIR/dists/unstable/main/source/Release" << __EOF__
Archive: unstable
Component: main
Origin: Debian
Label: Debian
Architecture: source
__EOF__

ln -s unstable "$REPO_DIR/dists/sid"

cd "$REPO_DIR"
dpkg-scanpackages --arch i386 pool/ > dists/unstable/main/binary-i386/Packages
bzip2 -9fk dists/unstable/main/binary-i386/Packages
gzip -9f dists/unstable/main/binary-i386/Packages
dpkg-scanpackages --arch amd64 pool/ > dists/unstable/main/binary-amd64/Packages
bzip2 -9fk dists/unstable/main/binary-amd64/Packages
gzip -9f dists/unstable/main/binary-amd64/Packages
dpkg-scanpackages --arch armel pool/ > dists/unstable/main/binary-armel/Packages
bzip2 -9fk dists/unstable/main/binary-armel/Packages
gzip -9f dists/unstable/main/binary-armel/Packages
dpkg-scanpackages --arch mipsel pool/ > dists/unstable/main/binary-mipsel/Packages
bzip2 -9fk dists/unstable/main/binary-mipsel/Packages
gzip -9f dists/unstable/main/binary-mipsel/Packages
dpkg-scansources pool/ > dists/unstable/main/source/Sources
bzip2 -9fk dists/unstable/main/source/Sources
gzip -9f dists/unstable/main/source/Sources
cd ../

cd "$REPO_DIR/dists"
cat > unstable/Release << __EOF__
Origin: pyneo
Label: pyneo
Suite: unstable
Codename: sid
Date: `date -R`
Architectures: amd64 armel i386 mipsel
Components: main
Description: pyneo dailies
MD5Sum:
__EOF__
for f in `find . -regex "./unstable/main/[^/]+/\(Packages\|Sources\|\Release\).*"`; do
	md5sum $f | awk '{printf " %s ", $1}' >> unstable/Release
	stat --printf="%s\t%n\n" $f >> unstable/Release
done
cd ../..

#gpg --detach-sign --armor --sign -o $REPO_DIR/Release.gpg $REPO_DIR/Release
