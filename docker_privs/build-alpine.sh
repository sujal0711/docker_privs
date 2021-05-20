#!/bin/sh


# Make sure the usual locations are in PATH
PATH=$PATH:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

key_sha256sums="9c102bcc376af1498d549b77bdbfa815ae86faa1d2d82f040e616b18ef2df2d4  alpine-devel@lists.alpinelinux.org-4a6a0840.rsa.pub
2adcf7ce224f476330b5360ca5edb92fd0bf91c92d83292ed028d7c4e26333ab  alpine-devel@lists.alpinelinux.org-4d07755e.rsa.pub
ebf31683b56410ecc4c00acd9f6e2839e237a3b62b5ae7ef686705c7ba0396a9  alpine-devel@lists.alpinelinux.org-5243ef4b.rsa.pub
1bb2a846c0ea4ca9d0e7862f970863857fc33c32f5506098c636a62a726a847b  alpine-devel@lists.alpinelinux.org-524d27bb.rsa.pub
12f899e55a7691225603d6fb3324940fc51cd7f133e7ead788663c2b7eecb00c  alpine-devel@lists.alpinelinux.org-5261cecb.rsa.pub"


get_static_apk () {
    wget="wget -q -O -"
    pkglist=alpine-keys:apk-tools-static
    auto_repo_dir=

    if [ -z "$repository" ]; then
        url=http://dl-cdn.alpinelinux.org/alpine/
	yaml_path="latest-stable/releases/$apk_arch/latest-releases.yaml"
        if [ -z "$release" ]; then
            echo -n "Determining the latest release... "
            release=$($wget $url/$yaml_path | \
	        awk '$1 == "branch:" {print $2; exit 0}')
            if [ -z "$release" ]; then
                release=$($wget $url/.latest.$apk_arch.txt | \
                    cut -d " " -f 3 | cut -d / -f 1 | uniq)
            fi
            if [ -z "$release" ]; then
                echo failed
                return 1
            fi
            echo $release
        fi
        auto_repo_dir=$release/main
        repository=$url/$auto_repo_dir
        pkglist=$pkglist:alpine-mirrors
    fi

    echo "Using static apk from $repository/$apk_arch"
    wget="$wget $repository/$apk_arch"

    # parse APKINDEX to find the current versions
    static_pkgs=$($wget/APKINDEX.tar.gz | \
        tar -Oxz APKINDEX | \
        awk -F: -v pkglist=$pkglist '
            BEGIN { split(pkglist,pkg) }
            $0 != "" { f[$1] = $2 }
            $0 == "" { for (i in pkg)
                           if (pkg[i] == f["P"])
                               print(f["P"] "-" f["V"] ".apk") }')
    [ "$static_pkgs" ] || return 1

    mkdir -p "$rootfs" || return 1
    for pkg in $static_pkgs; do
        echo "Downloading $pkg"
        $wget/$pkg | tar -xz -C "$rootfs"
    done

    # clean up .apk meta files
    rm -f "$rootfs"/.[A-Z]*

    # verify checksum of the key
    keyname=$(echo $rootfs/sbin/apk.static.*.pub | sed 's/.*\.SIGN\.RSA\.//')
    checksum=$(echo "$key_sha256sums" |  grep -w "$keyname")
    if [ -z "$checksum" ]; then
        echo "ERROR: checksum is missing for $keyname"
        return 1
    fi
    (cd $rootfs/etc/apk/keys && echo "$checksum" | sha256sum -c -) || return 1

    # verify the static apk binary signature
    APK=$rootfs/sbin/apk.static
    openssl dgst -sha1 -verify $rootfs/etc/apk/keys/$keyname \
        -signature "$APK.SIGN.RSA.$keyname" "$APK" || return 1

    if [ "$auto_repo_dir" ]; then
        mirror_list=$rootfs/usr/share/alpine-mirrors/MIRRORS.txt

        mkdir -p $rootfs/usr/share/alpine-mirrors/
        wget http://alpine.mirror.wearetriple.com/MIRRORS.txt -O $rootfs/usr/share/alpine-mirrors/MIRRORS.txt

        mirror_count=$(wc -l $mirror_list | cut -d " " -f 1)
        random=$(hexdump -n 2 -e '/2 "%u"' /dev/urandom)
        repository=$(sed $(expr $random % $mirror_count + 1)\!d \
            $mirror_list)/$auto_repo_dir
        echo "Selecting mirror $repository"
    fi
}

install_alpine() {
    mkdir -p "$rootfs"/etc/apk || return 1
    : ${keys_dir:=/etc/apk/keys}
    if ! [ -d "$rootfs"/etc/apk/keys ] && [ -d "$keys_dir" ]; then
        cp -r "$keys_dir" "$rootfs"/etc/apk/keys
    fi
    if [ -n "$repository" ]; then
        echo "$repository" > "$rootfs"/etc/apk/repositories
    else
        cp /etc/apk/repositories "$rootfs"/etc/apk/repositories || return 1
        if [ -n "$release" ]; then
            sed -E -i "s:/[^/]+/([^/]+)$:/$release/\\1:" \
                "$rootfs"/etc/apk/repositories
        fi
    fi
    opt_arch=
    if [ -n "$apk_arch" ]; then
        opt_arch="--arch $apk_arch"
    fi
    $APK add -U --initdb --root $rootfs $opt_arch "$@" alpine-base
}

configure_alpine() {
    cat >"$rootfs"/etc/inittab<<EOF
::sysinit:/sbin/rc sysinit
::sysinit:/sbin/rc boot
::wait:/sbin/rc default
::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/rc shutdown
EOF

    # configure the network using dhcp
    cat <<EOF > $rootfs/etc/network/interfaces
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

    # start services
    ln -s /etc/init.d/bootmisc "$rootfs"/etc/runlevels/boot/bootmisc
    ln -s /etc/init.d/networking "$rootfs"/etc/runlevels/boot/networking
    ln -s /etc/init.d/syslog "$rootfs"/etc/runlevels/boot/syslog

    # cleanup
    rm -rf "$rootfs/var/cache/apk"/*
    rm -f "$rootfs/sbin"/apk.static*

    return 0
}

create_metadata() {
    release_epoch=$(date +%s)
    release_date=$(date +%Y%m%d_%H:%M)

    cat <<EOF > metadata.yaml
{
    "architecture": "$arch",
    "creation_date": $release_epoch,
    "properties": {
        "architecture": "$arch",
        "description": "alpine $release ($release_date)",
        "name": "alpine-$release-$release_date",
        "os": "alpine",
        "release": "$release",
        "variant": "default"
    },
    "templates": {
        "/etc/hostname": {
            "template": "hostname.tpl",
            "when": [
                "create"
            ]
        },
        "/etc/hosts": {
            "template": "hosts.tpl",
            "when": [
                "create"
            ]
        }
    }
}
EOF

    mkdir -p templates

    cat <<EOF > templates/hostname.tpl
{{ container.name }}
EOF

    cat <<EOF > templates/hosts.tpl
127.0.0.1   localhost
127.0.1.1   {{ container.name }}

# The following lines are desirable for IPv6 capable hosts
::1     ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

    return 0
}

package_image() {
    release_date=$(date +%Y%m%d_%H%M)

    tar -zcf alpine-$release-$arch-$release_date.tar.gz --numeric-owner metadata.yaml templates rootfs
    rm -f metadata.yaml
    rm -rf templates
    rm -rf rootfs
}

die() {
    echo "$@" >&2
    exit 1
}

usage() {
    cat >&2 <<EOF
Usage: $(basename $0) [-h|--help] [-r|--repository <url>]
                   [-R|--release <release>] [-a|--arch <arch>]
                   [PKG...]
EOF
}

usage_err() {
    usage
    exit 1
}

rootfs="$(pwd)/rootfs"
release=
arch=$(uname -m)

# template requires root
if [ $(id -u) -ne 0 ]; then
   echo "$(basename $0): must be run as root" >&2
   exit 1
fi

options=$(getopt -o h:r:R:a: -l help,repository:,release:,arch: -- "$@")
[ $? -eq 0 ] || usage_err
eval set -- "$options"

while [ $# -gt 0 ]; do
    case "$1" in
    -h|--help)
        usage
        exit 0
        ;;
    -r|--repository)
        repository=$2
	;;
    -R|--release)
        release=$2
        ;;
    -a|--arch)
        arch=$2
        ;;
    --)
	shift
        break;;
    esac
    shift 2
done


if [ -z "$rootfs" ]; then
    rootfs="$(pwd)/rootfs"
fi

apk_arch=$arch

case "$arch" in
    i[3-6]86)
        apk_arch=x86
        ;;
    x86)
        ;;
    x86_64|"")
        ;;
    arm*)
        apk_arch=armhf
        ;;
    *)
        die "unsupported architecture: $arch"
        ;;
esac

: ${APK:=apk}
if ! which $APK >/dev/null; then
    get_static_apk || die "Failed to download a valid static apk"
fi

install_alpine "$@" || die "Failed to install rootfs"
configure_alpine || die "Failed to configure rootfs"
create_metadata || die "Failed to create metadata"
package_image || die "Failed to package image"

