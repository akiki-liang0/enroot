cat << EOF > "${archname}"
#! /bin/bash

set -euo pipefail
shopt -s lastpipe

readonly description="${LABEL}"
readonly compression="${COMPRESS}"
readonly target_dir="${archdirname}"
readonly file_sizes=(${filesizes})
readonly sha256_sum="${SHAsum}"
readonly skip_lines="${SKIP}"
readonly total_size="${USIZE}"
readonly decompress="${GUNZIP_CMD}"
readonly script_args=(${SCRIPTARGS})

EOF
cat << 'EOF' >> "${archname}"

readonly libexec_dir="${script_args[0]}"
readonly sysconf_dir="${script_args[1]}"
readonly usrconf_dir="${script_args[2]}"

bundle::_rm() {
    local -r path="$1"

    rm --one-file-system --preserve-root -rf "${path}" 2> /dev/null || \
    { chmod -R +w "${path}"; rm --one-file-system --preserve-root -rf "${path}"; }
}

bundle::_dd() {
    local -r file="$1"
    local -r offset="$2"
    local -r size="$3"
    local -r progress="$4"

    local progress_cmd="cat"
    local -r blocks=$((size / 1024))
    local -r bytes=$((size % 1024))

    if [ -n "${progress}" ]; then
        if command -v pv > /dev/null; then
            progress_cmd="pv -s ${size}"
        fi
    fi

    dd status=none if="${file}" ibs="${offset}" skip=1 obs=1024 conv=sync | { \
      if [ "${blocks}" -gt 0 ]; then dd status=none ibs=1024 obs=1024 count="${blocks}"; fi; \
      if [ "${bytes}" -gt 0 ]; then dd status=none ibs=1 obs=1024 count="${bytes}"; fi; \
    } | ${progress_cmd}
}

bundle::check() {
    local -r file="$1"

    local -i offset=0
    local sum1=""
    local sum2=""

    if [[ "0x${sha256_sum}" -eq 0x0 ]]; then
        return
    fi

    offset=$(head -n "${skip_lines}" "${file}" | wc -c | tr -d ' ')

    for i in "${!file_sizes[@]}"; do
        cut -d ' ' -f $((i + 1)) <<< "${sha256_sum}" | read -r sum1
        bundle::_dd "${file}" "${offset}" "${file_sizes[i]}" "" | sha256sum | read -r sum2 x
        if [ "${sum1}" != "${sum2}" ]; then
            printf "ERROR: Checksum validation failed\n" >&2
            exit 1
        fi
        offset=$((offset + ${file_sizes[i]}))
    done
}

bundle::extract() {
    local -r file="$1"
    local -r dest="$2"
    local -r quiet="$3"

    local progress=""
    local -i offset=0
    local -i diskspace=0

    if ! command -v "${decompress%% *}" > /dev/null; then
        printf "ERROR: Command not found: %s\n" "${decompress%% *}" >&2
        exit 1
    fi
    if [ -z "${quiet}" ] && [ -t 2 ]; then
        progress=y
    fi

    offset=$(head -n "${skip_lines}" "${file}" | wc -c | tr -d ' ')
    diskspace=$(df -k --output=avail "${dest}" | tail -1)

    if [ "${diskspace}" -lt "${total_size}" ]; then
        printf "ERROR: Not enough space left in %s (%s KB needed)\n" "$(dirname "${dest}")" "${total_size}" >&2
        exit 1
    fi
    for i in "${!file_sizes[@]}"; do
        bundle::_dd "${file}" "${offset}" "${file_sizes[i]}" "${progress}" | ${decompress} | tar -C "${dest}" -pxf -
        offset=$((offset + ${file_sizes[i]}))
    done

    find "${dest}" "${dest}/usr" -maxdepth 1 -type d ! -perm -u+w -exec chmod u+w {} \+
    touch "${dest}"
}

bundle::usage() {
    printf "Usage: %s [options] [--] [COMMAND] [ARG...]\n" "${0##*/}"
    if [ "${description}" != "none" ]; then
        printf "\n%s\n" "${description}"
    fi
    cat <<- EOF
	
	 Options:
	   -i, --info           Display the information about this bundle
	   -k, --keep           Keep the bundle extracted in the target directory
	   -q, --quiet          Supress the progress bar output
	
	   -c, --conf CONFIG    Specify a configuration script to run before the container starts
	   -e, --env KEY[=VAL]  Export an environment variable inside the container
	   -m, --mount FSTAB    Perform a mount from the host inside the container (colon-separated)
	   -r, --root           Ask to be remapped to root inside the container
	   -w, --rw             Make the container root filesystem writable
	EOF
    exit 0
}

bundle::info() {
    if [[ "0x${sha256_sum}" -ne 0x0 ]]; then
        printf "Checksum: %s\n" "${sha256_sum}"
    fi
    cat <<- EOR
	Compression: ${compression}
	Description: ${description}
	Runtime version: @version@
	Target directory: ${target_dir}
	Uncompressed size: ${total_size} KB
	EOR
    exit 0
}

keep=""
quiet=""
conf=""
mounts=()
environ=()
rw=""
root=""

bundle::check "$0"

while [ $# -gt 0 ]; do
    case "$1" in
    -i|--info)
        bundle::info ;;
    -k|--keep)
        keep=y
        shift
        ;;
    -q|--quiet)
        quiet=y
        shift
        ;;
    -c|--conf)
        [ -z "${2-}" ] && bundle::usage
        conf="$2"
        shift 2
        ;;
    -m|--mount)
        [ -z "${2-}" ] && enroot::usage
        mounts+=("$2")
        shift 2
        ;;
    -e|--env)
        [ -z "${2-}" ] && enroot::usage
        environ+=("$2")
        shift 2
        ;;
    -r|--root)
        root=y
        shift
        ;;
    -w|--rw)
        rw=y
        shift
        ;;
    --)
        shift; break ;;
    -?*)
        bundle::usage ;;
    *)
        break ;;
    esac
done

if [ -n "${keep}" ]; then
    rootfs=$(readlink -f "${target_dir}")
    rundir="${rootfs%/*}/.${rootfs##*/}"
    if [ -e "${rootfs}" ]; then
        printf "ERROR: File already exists: %s\n" "${rootfs}" >&2
        exit 1
    fi
    mkdir -p "${rootfs}" "${rundir}"
    trap "rmdir '${rundir}' 2> /dev/null" EXIT
else
    rootfs=$(mktemp -d --tmpdir "${target_dir##*/}.XXXXXXXXXX")
    rundir="${rootfs%/*}/.${rootfs##*/}"
    mkdir -p "${rundir}"
    trap "bundle::_rm '${rootfs}'; rmdir '${rundir}' 2> /dev/null" EXIT
fi

bundle::extract "$0" "${rootfs}" "${quiet}"
set +e
(
    set -e

    export ENROOT_LIBEXEC_PATH="${rootfs}${libexec_dir}"
    export ENROOT_SYSCONF_PATH="${rootfs}${sysconf_dir}"
    export ENROOT_CONFIG_PATH="${rootfs}${usrconf_dir}"
    export ENROOT_DATA_PATH="${rootfs}"
    export ENROOT_RUNTIME_PATH="${rundir}"
    export ENROOT_LOGIN_SHELL="/bin/sh"
    export ENROOT_ROOTFS_RW="${rw}"
    export ENROOT_REMAP_ROOT="${root}"

    source "${ENROOT_LIBEXEC_PATH}/runtime.sh"

    runtime::start . "${conf}" \
      "$(IFS=$'\n'; echo ${mounts[*]+"${mounts[*]}"})"  \
      "$(IFS=$'\n'; echo ${environ[*]+"${environ[*]}"})" \
      "$@"
)
exit $?
EOF
