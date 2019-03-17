#!/bin/sh -e

# Rquires: mkdir(1), rm(1), mktemp(1)

# Use KEEP_LOG=1 to keep installation logs in ".install" and entire <netctl_dir>
# on failure to install to temporary location.

################################################################################

prog_name="${0##*/}"

# Usage: msg <fmt> ...
msg()
{
	local rc=$?

	local func="${FUNCNAME:-msg}"

	local fmt="${1:?missing 1st arg to ${func}() (<fmt>)}"
	shift

	[ $V -le 0 ] || printf -- "${fmt}" "$@"

	return $rc
}

# Usage: abort <fmt> ...
abort()
{
	V=1 msg "$@" >&2
	local rc=$?
	trap - EXIT
	exit $rc
}

# Usage: exec_vars() [NAME=VAL...] [--] <command> [<args>...]
exec_vars()
{
	local func="${FUNCNAME:-exec_vars}"

	# Bash and dash behaves differently when calling
	# with variable preset: use function with local
	# variables to handle both.
	while [ $# -gt 0 ]; do
		case "$1" in
			*=*)  eval "local '$1'; export '${1%%=*}'" ;;
			--)   shift; break ;;
			*)    break ;;
		esac
		shift
	done

	eval "$@"
}

# Usage: usage
usage()
{
	local rc=$?
	printf -- '
Usage: %s -s <netctl_git> [-d <netctl_dir>] [ -t <dir> ] [-o] [-b <ext>] [-h|-u]
where
    -s <netctl_git> - directory with netctl project or "" (empty) to try
                      this script directory ("%s")
    -d <netctl_dir> - install destination directory where "root" and "dest"
                      subdirs will be created (default: mktemp -d "%s.XXXXXXXX")
    -t <dir>        - absolute path prefix on target system to the installed
                      files (default: "%s")
    -o              - force install to skip privileged parts like user account
                      creation even if running as superuser (default: no)
    -b <ext>        - backup existing destination regular file or symlink when
                      exists by appending .<ext>ension to entry name on rename;
                      skip on failure (default: disabled, <ext> is "inst-sh")
    -h|-u           - display this help message

' "$prog_name" "$SOURCE" "$NAME" "$TARGET"
	exit $rc
}

# Program (script) name
prog_name="${0##*/}"

# Verbosity: log only fatal errors
[ "$V" -ge 0 -o "$V" -le 0 ] 2>/dev/null || V=0

## Try to determine SOURCE
SOURCE="${0%/*}"
# Make it absolute path
SOURCE="$(cd "$SOURCE" && echo "$PWD")" &&
[ "$SOURCE/deploy.sh" -ef "$0" ] ||
	abort 'cannot find directory containing this script\n'
NAME="${SOURCE##*/}"

TARGET='/'

## Parse command line arguments
netctl_git=''
netctl_sys="$TARGET"
netctl_ord=''
netctl_bak=''
while getopts 's:d:t:ob:hu' c; do
	case "$c" in
		s) netctl_git="-$OPTARG" ;;
		d) netctl_dir="$OPTARG" ;;
		t) netctl_sys="$OPTARG" ;;
		o) netctl_ord=y ;;
		b) netctl_bak="${OPTARG:-inst-sh}" ;;
		h|u) usage ;;
		*) ! : || usage ;;
	esac
done

# no extra arguments
shift $((OPTIND - 1))
[ $# -eq 0 ] || usage

# mandatory argument
[ -n "$netctl_git" ] || usage
netctl_git="${netctl_git#-}"

# -s <netctl_git>
netctl_git="${netctl_git:-$SOURCE}"
netctl_install_sh="$netctl_git/install.sh"
[ -e "$netctl_git/.git" -a -e "$netctl_install_sh" ] || \
	abort '"%s" is not a <netctl_git> directory\n' "$netctl_git"

# -d <netctl_dir>
if [ -n "$netctl_dir" ]; then
	[ -d "$netctl_dir" -o ! -e "$netctl_dir" ] || \
		abort '"%s" exists and not a directory\n' "$netctl_dir"
	netctl_dir_is_temp=
else
	netctl_dir="$(mktemp -d "$NAME.XXXXXXXX")" || \
		abort 'fail to make temporary directory for install\n'
	netctl_dir_is_temp=y
fi

## Prepare cleanup
exit_handler()
{
	local rc=$?

	set +e

	if [ $rc -eq 0 ]; then
		msg 'success\n'

		# Report install location: can be used by package manager
		exec_vars V=1 -- msg "'netctl_dir:%s\n'" "'$netctl_dir'"

		netctl_dir="$DEST/.install"
	elif [ -n "$netctl_dir_is_temp" ]; then
		msg 'failure\n'
	else
		netctl_dir=
	fi

	if [ -z "$KEEP_LOG" -a -n "$netctl_dir" ]; then
		msg 'cleaning up (remove "%s")\n' "$netctl_dir"
		rm -rf "$netctl_dir" ||:
	fi
}
trap exit_handler EXIT

## Install netctl
msg 'installing to "%s"\n' "$netctl_dir"

export ROOT="$netctl_dir/root"
export DEST="$netctl_dir/dest"
export TARGET="$netctl_sys"

mkdir -p "$ROOT" "$DEST" || \
	abort 'fail to make "root" and "dest" subdirs under "%s"\n' \
		"$netctl_dir"

# Reserved value for uid/gid is -1 as per
# kernel/sys.c::setresuid() syscall.
#
# Use 0xffffffff as -1 as $(printf '%#x' -1) will
# give 64-bit value while uid/gid are 32-bit.
RSVD_UGID=0xffffffff

exec_vars V=$V ${netctl_ord:+INSTALL_EUID=$RSVD_UGID INSTALL_EGID=$RSVD_UGID} \
	BACKUP="$netctl_bak" EEXIST='' -- \
	"$netctl_install_sh" || \
	abort 'fail to install netctl using "%s" to "%s"\n' \
		"$netctl_install_sh" "$netctl_dir"

exit 0
