#! @bash@/bin/sh -e

shopt -s nullglob

export PATH=/empty:@path@

usage() {
    echo "usage: $0 -t <timeout> -c <path-to-default-configuration> [-d <boot-dir>] [-g <num-generations>] [-n <dtbName>] [-r]" >&2
    exit 1
}

timeout=                # Timeout in centiseconds
menu=1                  # Enable menu by default
default=                # Default configuration
target=/boot            # Target directory
numGenerations=0        # Number of other generations to include in the menu


# cheap hack to parse just the UUID
rootUUID=$(basename @rootDevice@)


while getopts "t:c:d:g:n:r:u" opt; do
    case "$opt" in
        t) # U-Boot interprets '0' as infinite
            if [ "$OPTARG" -lt 0 ]; then
                # When negative (or null coerced to -1), disable timeout which means that we wait forever for input
                timeout=0
            elif [ "$OPTARG" = 0 ]; then
                # When zero, which means disabled in Nix module, disable menu which results in instant boot of the default item
                # .. timeout is actually ignored by u-Boot but set here for the rest of the script
                timeout=1
                menu=0
            else
                # Positive results in centi-seconds of timeout, which when passed with no input results in boot of the default item
                timeout=$((OPTARG * 10))
            fi
            ;;
        c) default="$OPTARG" ;;
        d) target="$OPTARG" ;;
        g) numGenerations="$OPTARG" ;;
        n) dtbName="$OPTARG" ;;
        r) noDeviceTree=1 ;;
        \?) usage ;;
    esac
done

[ "$timeout" = "" -o "$default" = "" ] && usage

mkdir -p $target/menuboot
mkdir -p $target/extlinux

# Convert a path to a file in the Nix store such as
# /nix/store/<hash>-<name>/file to <hash>-<name>-<file>.
cleanName() {
    local path="$1"
    echo "$path" | sed 's|^/nix/store/||' | sed 's|/|-|g'
}

# Copy a file from the Nix store to $target/menuboot.
declare -A filesCopied

copyToKernelsDir() {
    local src=$(readlink -f "$1")
    local dst="$target/menuboot/$(cleanName $src)"
    # Don't copy the file if $dst already exists.  This means that we
    # have to create $dst atomically to prevent partially copied
    # kernels or initrd if this script is ever interrupted.
    if ! test -e $dst; then
        local dstTmp=$dst.tmp.$$
        cp -r $src $dstTmp
        mv $dstTmp $dst
    fi
    filesCopied[$dst]=1
    result=$dst
}

# Copy its kernel, initrd and dtbs to $target/menuboot, and echo out an
# extlinux menu entry
addEntry() {
    local path="@kernelPath@"
    local tag="$2" # Generation number or 'default'

    if ! test -e $path/kernel -a -e $path/initrd; then
        return
    fi

    copyToKernelsDir "$path/vmlinuz"; kernel=$result
    dtbDir=$(readlink -m "$path/dtb")
    if [ -e "$dtbDir" ]; then
        copyToKernelsDir "$dtbDir"; dtbs=$result
    fi

    timestampEpoch=$(stat -L -c '%Z' $path)

    timestamp=$(date "+%Y-%m-%d %H:%M" -d @$timestampEpoch)
    extraParams="$(cat $path/kernel-params)"

    echo
    echo "LABEL nixos-menuboot-$tag"
    if [ "$tag" = "default" ]; then
        echo "  MENU LABEL NixOS - menuboot - Default"
    else
        echo "  MENU LABEL NixOS - menuboot - $tag ($timestamp)"
    fi
    echo "  LINUX ../menuboot/$(basename $kernel)"
    echo "  APPEND init=$path/init root=UUID=$rootUUID $extraParams"

    if [ -n "$noDeviceTree" ]; then
        return
    fi

    if [ -d "$dtbDir" ]; then
        # if a dtbName was specified explicitly, use that, else use FDTDIR
        if [ -n "$dtbName" ]; then
            echo "  FDT ../menuboot/$(basename $dtbs)/${dtbName}"
        else
            echo "  FDTDIR ../menuboot/$(basename $dtbs)"
        fi
    else
        if [ -n "$dtbName" ]; then
            echo "Explicitly requested dtbName $dtbName, but there's no FDTDIR - bailing out." >&2
            exit 1
        fi
    fi
}

tmpFile="$target/extlinux/extlinux.conf.tmp.$$"

cat > $tmpFile <<EOF
# Generated file, all changes will be lost on nixos-rebuild!

# Change this to e.g. nixos-menuboot-42 to temporarily boot to an older configuration.
DEFAULT nixos-menuboot-default

TIMEOUT $timeout
EOF

[ "$menu" == "1" ] \
  && echo "MENU TITLE ------------------------------------------------------------" >> $tmpFile

addEntry $default default >> $tmpFile

if [ "$numGenerations" -gt 0 ]; then
    # Add up to $numGenerations generations of the system profile to the menu,
    # in reverse (most recent to least recent) order.
    for generation in $(
            (cd /nix/var/nix/profiles && ls -d system-*-link) \
            | sed 's/system-\([0-9]\+\)-link/\1/' \
            | sort -n -r \
            | head -n $numGenerations); do
        link=/nix/var/nix/profiles/system-$generation-link
        addEntry $link "${generation}-default"
        for specialisation in $(
            ls /nix/var/nix/profiles/system-$generation-link/specialisation \
            | sort -n -r); do
            link=/nix/var/nix/profiles/system-$generation-link/specialisation/$specialisation
            addEntry $link "${generation}-${specialisation}"
        done
    done >> $tmpFile
fi

mv -f $tmpFile $target/extlinux/extlinux.conf

# Remove obsolete files from $target/menuboot.
for fn in $target/menuboot/*; do
    if ! test "${filesCopied[$fn]}" = 1; then
        echo "Removing no longer needed boot file: $fn"
        chmod +w -- "$fn"
        rm -rf -- "$fn"
    fi
done
