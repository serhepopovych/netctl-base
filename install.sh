#!/bin/sh -e

# Requires: id(1), mkdir(1), ln(1), cp(1), mv(1), rm(1), readlink(1), sed(1)
# Requires: chown(1), chmod(1), cmp(1), mktemp(1), sort(1), tr(1)

# Usage: pass() [...]
pass()
{
	:
}

# Usage: fail() [...]
fail()
{
	! :
}

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

# Usage: log <fmt> ...
log()
{
	local rc=$?

	local func="${FUNCNAME:-log}"

	local fmt="${1:?missing 1st arg to ${func}() (<fmt>)}"
	shift
	local verdict

	if [ -z "$LOG_MSG" ]; then
		[ $rc -eq 0 ] && verdict='success' || verdict='failure'
	else
		verdict=''
	fi

	[ ${#L} -ne 1 ] || eval printf ${INSTALL_LOG:+>>"'$INSTALL_LOG'"} -- \
		"'%s: %s: ${fmt}%s'" "'${NAME:-unknown}'" "'$L'" '"$@"' \
		"'${verdict:+: $verdict
}'"
	return $rc
}

# Usage: log_msg <fmt> ...
log_msg()
{
	local func="${FUNCNAME:-log_msg}"
	local LOG_MSG="${func}"

	log "$@"
}

# Usage: return_var() <rc> [<result> [<var>]]
return_var()
{
	local func="${FUNCNAME:-return_var}"

	local rv_rc="${1:?missing 1st arg to ${func}() (<rc>)}"
	local rv_result="$2"
	local rv_var="$3"

	if [ -n "${rv_result}" ]; then
		if [ -n "${rv_var}" ]; then
			eval "${rv_var}='${rv_result}'"
		else
			echo "${rv_result}"
		fi
	fi

	return ${rv_rc}
}

# Usage: normalize_path() <path> [<var_result>]
normalize_path()
{
	local func="${FUNCNAME:-normalize_path}"

	local path="${1:?missing 1st arg to ${func}() (<path>)}"
	local file=''

	if [ ! -d "${path}" ]; then
		file="${path##*/}"
		[ -n "$file" ] || return
		path="${path%/*}"
		[ -d "$path" ] || return
	fi

	cd "${path}" && path="${PWD}${file:+/$file}" && cd - >/dev/null
	return_var $? "$path" "$2"
}

# Usage: relative_path <src> <dst> [<var_result>]
relative_path()
{
	local func="${FUNCNAME:-relative_path}"

	local rp_src="${1:?missing 1st arg to ${func}() (<src>)}"
	local rp_dst="${2:?missing 2d arg to ${func}() (<dst>)}"

	# add last component from src if dst ends with '/'
	[ -n "${rp_dst##*/}" ] || rp_dst="${rp_dst}${rp_src##*/}"

	# normalize pathes first
	normalize_path "${rp_src}" rp_src || return
	normalize_path "${rp_dst}" rp_dst || return

	# strip leading and add trailing '/'
	rp_src="${rp_src#/}/"
	rp_dst="${rp_dst#/}/"

	while :; do
		[ "${rp_src%%/*}" = "${rp_dst%%/*}" ] || break

		rp_src="${rp_src#*/}" && [ -n "${rp_src}" ] || return
		rp_dst="${rp_dst#*/}" && [ -n "${rp_dst}" ] || return
	done

	# strip trailing '/'
	rp_dst="${rp_dst%/}"
	rp_src="${rp_src%/}"

	# add leading '/' for dst only: for src we will add with sed(1) ../
	rp_dst="/${rp_dst}"

	# add leading '/' to dst, replace (/[^/])+ with ../
	rp_dst="$(echo "${rp_dst%/*}" | \
		  sed -e 's|\(/[^/]\+\)|../|g')${rp_src}" || \
		return

	return_var 0 "${rp_dst}" "$3"
}

# Usage: install_sh() <src_prefix> <dst_prefix> [files and/or dirs...]
# Following environment variables can override functionality:
#  MKDIR  - create destination directories (default: install -d), use /bin/false
#           to force destination directory tree to exist and match source
#  BACKUP - backup file extension or empty to disable backups (default: empty)
#  EEXIST - fail when non-empty, destination file exists and backup either
#           disabled or failed (default: empty)
#  REG_FILE_COPY - copy regular file (default: cp -dp)
#  SCL_FILE_COPY - copy special file like device or socket (default: ln -snf)
install_sh()
{
	local func="${FUNCNAME:-install_sh}"

	local sp="${1:?missing 1st arg to ${func}() (<src_prefix>)}"
	local dp="${2:?missing 2d arg to ${func}() (<dst_prefix>)}"
	shift 2

	while [ $# -gt 1 ]; do
		[ -z "$1" ] || "${func}" "$sp" "$dp" "$1" || return
		shift
	done

	local fd="${1##/}"
	[ -n "$fd" ] || return 0

	local src="$sp/$fd"
	[ -e "$src" ] || return 0
	src="${src%%/}"
	local dst="$dp/$fd"

	local s d

	local MKDIR="${MKDIR:-mkdir -p}"
	local BACKUP="${BACKUP:-}"
	local EEXIST="${EEXIST:-}"
	local REG_FILE_COPY="${REG_FILE_COPY:-cp -dp}"
	local SCL_FILE_COPY="${SCL_FILE_COPY:-ln -snf}"

	[ -L "$src" -o ! -d "$src" ] || src="$src/* $src/.*"

	d="$dst"
	if [ ! -e "$d" ]; then
		# Non-existing file?
		if [ -n "${d##*/}" ]; then
			d="${d%/*}"
			[ ! -e "$d" ] || d=
		fi
		if [ -n "$d" ]; then
			$MKDIR "$d" || return
		fi
	fi

	for s in $src; do
		# Skip special directories
		src="${s##*/}"
		[ "$src" != '.' -a "$src" != '..' ] || continue

		# Directories are first
		if [ ! -L "$s" -a -d "$s" ]; then
			"${func}" "$sp" "$dp" "${s#$sp/}/" || return
			continue
		fi

		# If $src is empty directory wildcard does not expand
		[ -e "$s" ] || continue

		# Make backup of destination file
		d="$dst"
		if [ ! -L "$d" -a -d "$d" ]; then
			d="$d/${s##*/}"
		fi

		if [ -e "$d" ]; then
			# Same as source: skip
			[ ! "$d" -ef "$s" ] || continue
			[ -d "$d" -o -d "$s" ] || ! cmp -s "$d" "$s" || continue

			if [ -n "$BACKUP" -a \( -L "$d" -o -f "$d" \) ] &&
			   mv -f "$d" "$d.$BACKUP"; then
				:
			else
				[ -z "$EEXIST" ] || return
			fi
		fi

		# Symlinks, files and specials are next
		if [ -L "$s" -o -f "$s" ]; then
			$REG_FILE_COPY "$s" "$d" || return
		elif [ -e "$s" ]; then
			$SCL_FILE_COPY "$s" "$d" || return
		fi
	done
}

# Usage walk_paths() <action> [<path>...]
walk_paths()
{
	local func="${FUNCNAME:-walk_paths}"

	local action="${1:?missing 1st arg to ${func}() (<action>)}"
	shift

	while [ $# -gt 1 ]; do
		[ -z "$1" ] || "${func}" "$action" "$1" || return
		shift
	done

	local path="$1"
	[ -n "$path" ] || return 0

	[ ! -L "$path" ] || return 0
	[ ! -d "$path" ] || path="$path/* $path/.*"

	for p in $path; do
		# Skip special directories
		path="${p##*/}"
		[ "$path" != '.' -a "$path" != '..' ] || continue

		# Skip symlinks as they might point outside of tree
		[ ! -L "$p" ] || continue

		# Handle nested directories
		if [ -d "$p" ]; then
			"${func}" "$action" "$p" || return
			continue
		fi

		# If $src is empty directory wildcard does not expand
		[ -e "$p" ] || continue

		# Execute specific action for given path
		"$action" "$p" || return
	done
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

# Usage: inherit() <subproject>/<path_to_file>
inherit()
{
	local func="${FUNCNAME:-inherit}"

	local f="${1:?missing 1st arg to ${func}() (<subproject>/<path_to_file>)}"
	local sp="$SOURCE/.subprojects/${f%%/*}"
	f="${f#*/}"

	[ ! -f "$sp/$f" ] || exec_vars SOURCE="$sp" -- . "\$SOURCE/$f"
}

# Usage: subst_templates_sed <file>
subst_templates_sed()
{
	local f="$1"

	[ -f "$f" -a -s "$f" ] || return 0

	eval sed -i "\$f" $SUBST_TEMPLATES
}

# Register default hook. Can be overwritten in "vars-sh".
subst_templates_hook=''

# Usage: subst_templates <file>
subst_templates_typecheck_done=''
subst_templates()
{
	local func="${FUNCNAME:-subst_templates}"

	local rc

	# Typecheck registered hook
	if [ -z "$subst_templates_typecheck_done" ]; then
		if [ -n "$subst_templates_hook" ]; then
			rc="$(type "$subst_templates_hook" 2>/dev/null)"
			[ -z "${rc##*function*}" ] ||
				subst_templates_hook='subst_templates_sed'
		else
			subst_templates_hook='subst_templates_sed'
		fi
		subst_templates_typecheck_done=y
	fi

	local __ifs="${IFS}"
	IFS='
'
	"$subst_templates_hook" "$1"
	rc=$?
	IFS="${__ifs}"

	return_var $rc

	log 'replaced templates in "%s" file' "${1#$DEST/}"
}

# Usage: reg_file_copy()
reg_file_copy()
{
	local func="${FUNCNAME:-reg_file_copy}"

	local s="${1:?missing 1st arg to ${func}() (<src>)}"
	local d="${2:?missing 2d arg to ${func}() (<dst>)}"
	local t

	if [ -L "$s" ]; then
		t="$(cd "$SOURCE" && readlink -m "$s")" || return
		# Outside of SOURCE directory?
		[ ! -d "$t" ] || t="$t/."
		[ -z "${t##$SOURCE/*}" ] || return 0
		# Subproject responsibility?
		t="${t#$SOURCE}"
		[ -n "${t##*/.subprojects/*}" ] || return 0
		# Make path relative: we do not expect symlinks from DEST
		# to ROOT as pointless and DEST installed before ROOT
		t="$DEST$t"
		[ -e "$t" -o ! -d "$s" ] || mkdir -p "$t" || return
		relative_path "$t" "$d" s || return
		# Link it
		ln -snf "$s" "$d" || return
	else
		if [ -n "$DO_SUBST_TEMPLATES" ]; then
			# Copy source to temporary destination
			t="$(mktemp "$d.XXXXXXXX")" && cp -fp "$s" "$t" &&
				exec_vars L='' -- subst_templates "'$t'" || return

			if [ ! -d "$d" ] && cmp -s "$t" "$d"; then
				# Skip file with same contents
				rm -f "$t" ||:
				return
			else
				# Move new file
				mv -f "$t" "$d" && chmod -f go+r "$d" || return
			fi
		else
			# Copy regular file
			cp -fp "$s" "$d" || return
		fi
	fi

	log 'installed "%s" to "%s"' "${d#$TRGT/}" "$TRGT"
}

# Usage: install_root() [<file|dir>...]
install_root()
{
	local REG_FILE_COPY='reg_file_copy'
	local L='R'
	local TRGT="$ROOT"
	local DO_SUBST_TEMPLATES=y

	install_sh "$SOURCE" "$TRGT" "$@"
}

# Usage: install_dest() [<file|dir>...]
install_dest()
{
	local REG_FILE_COPY='reg_file_copy'
	local L='D'
	local TRGT="$DEST"

	install_sh "$SOURCE" "$TRGT" "$@"
}

# Usage: adj_rights() <owner> <mode> ...
adj_rights()
{
	local func="${FUNCNAME:-adj_rights}"

	local owner="$1"
	local mode="$2"
	shift 2
	local L='O'

	[ "$owner" != ':' ] || owner=''

	while [ $# -gt 0 ]; do
		[ -z "$owner" ] || chown "$owner" "$1" || return
		[ -z "$mode" ] || chmod "$mode"  "$1" || return

		log 'adjusted rights on "%s": owner(%s), mode(%s)' \
			"${1#$DEST/}" \
			"${owner:-not changed}" "${mode:-not changed}"
		shift
	done
}

NAME_UC="$(echo "$NAME" | tr '[:lower:]' '[:upper:]')"
begin_header_str="##### BEGIN ${NAME_UC} #####"
end_header_str="##### END ${NAME_UC} #####"

# Usage: begin_header <file>
begin_header()
{
	local func="${FUNCNAME:-begin_header}"

	local f="${1:?missing 1st arg to ${func}() (<file>)}"

	echo "$begin_header_str" >>"$f"
}

# Usage: end_header <file>
end_header()
{
	local func="${FUNCNAME:-end_header}"

	local f="${1:?missing 1st arg to ${func}() (<file>)}"

	echo "$end_header" >>"$f"
}

# Usage: prepare_file <file>
prepare_file()
{
	local func="${FUNCNAME:-prepare_file}"

	local f="${1:?missing 1st arg to ${func}() (<file>)}"

	if [ -e "$f" ]; then
		# Remove block wrapped by begin/end header
		[ -f "$f" ] || return
		sed -n -e "/$begin_header_str/,/$end_header_str/!p" -i "$f" ||:
	else
		# Make sure we are not ending with '/'
		[ -n "${f##*/}" ] || return

		local d="$ROOT/${f%/*}"
		if [ ! -d "$d" ]; then
			[ ! -e "$d" ] && mkdir -p "$d" || return
		fi

		# Create empty file
		: >"$f" || return
	fi
}

################################################################################

# Program (script) name
prog_name="${0##*/}"

# Verbosity: report errors by default
[ "$V" -le 0 -o "$V" -ge 0 ] 2>/dev/null || V=1

# Logging facility: G - Global
L='G'

# Try to determine SOURCE
SOURCE="${0%/*}"
# Make it absolute path
SOURCE="$(cd "$SOURCE" && echo "$PWD")" &&
[ "$SOURCE/install.sh" -ef "$0" -a -f "$SOURCE/vars-sh" ] ||
	abort '%s: cannot find project location\n' "$prog_name"
NAME="${SOURCE##*/}"

# Detect if running as base
[ ! -L "$SOURCE/install.sh" ] &&
	AS_BASE="$NAME" || AS_BASE=

if [ -z "$PARENT" ]; then
	# Destination to install
	export DEST="${DEST:-/}"

	if [ ! -L "$DEST" -a -d "$DEST" ]; then
		:
	elif [ ! -e "$DEST" ] && mkdir -p "$DEST"; then
		:
	else
		abort '%s: DEST="%s" exists and not a directory: aborting\n' \
			"$prog_name" "$DEST"
	fi

	# Destination on target system (useful for package build)
	export TARGET="${TARGET:-$DEST}"

	# System wide directory prefix
	[ -n "$ROOT" ] && ROOT="$(cd "$ROOT" 2>/dev/null && echo "$PWD")" || \
		ROOT="$DEST"
	export ROOT

	# Working directory
	export WORK_DIR="$DEST/.install"
	# Create installation log
	export INSTALL_LOG="$WORK_DIR/install.log"

	# Initialize install
	rm -rf "$WORK_DIR" ||:
	mkdir -p "$WORK_DIR" ||
		abort '%s: cannot create work directory "%s"\n' \
			"$prog_name" "$WORK_DIR"

	: >"$INSTALL_LOG" ||
		abort '%s: log file "%s" is not writable\n' \
			"$prog_name" "$INSTALL_LOG"
fi

# Make sure we run once per subproject
MARK_FILE="$WORK_DIR/do-$NAME"

if [ -e "$MARK_FILE" ]; then
	exec_vars L='S' -- \
		log_msg "'skipping as already installed (mark file "%s" exist)\n'" \
			"'${MARK_FILE#$DEST/}'"
	exit 0
else
	: >"$MARK_FILE" ||
		abort '%s: mark file "%s" is not writable\n' \
			"$prog_name" "$MARK_FILE"
fi

# Make sure we known effective uid/gid we running
INSTALL_EUID="${INSTALL_EUID:-${EUID:-$(id -u)}}" ||
	abort '%s: fail to get process effective UID\n' "$prog_name"
INSTALL_EGID="${INSTALL_EGID:-${EGID:-$(id -g)}}" ||
	abort '%s: fail to get process effective GID\n' "$prog_name"
export INSTALL_EUID INSTALL_EGID

# Configure EXIT "signal" handler
exit_handler()
{
	local rc=$?
	if [ $rc -ne 0 ]; then
		exec_vars V=1 -- msg "'%s: install exited with error %d\n'" \
			"'$NAME/install.sh'" $rc
	fi

	if [ -z "$PARENT" ]; then
		msg '%s: installation log file located at "%s"\n' \
			"$NAME" "$INSTALL_LOG"
	fi
}
trap exit_handler EXIT

# Source vars-sh with global variables and/or functions that may be
# exported to subprojects using shell export directive
. "$SOURCE/vars-sh"

# Prepare templates
SUBST_TEMPLATES="$(echo "$SUBST_TEMPLATES" |sort -u)"

# Call subprojects install
log_msg '---- Start subproject installations ----\n'

for sp in "$SOURCE/.subprojects"/*; do
	# Check subproject directory
	[ -d "$sp" ] || continue

	# Check it's install.sh
	install_sh="$sp/install.sh"
	if [ -f "$install_sh" -a \
	     -r "$install_sh" -a \
	     -x "$install_sh" ]; then
		# then execute
		exec_vars PARENT="$NAME" -- "$install_sh" ||
			abort '%s: subproject "%s/install.sh" failed\n' \
				"$prog_name" "${sp##*/}"
	fi
done

log_msg '---- Stop subproject installations ----\n'

# Install to the given destination (DEST)
install_dest \
	'/netctl'

# Install system wide (ROOT) configuration files
install_root \
	'/bin'    \
	'/boot'   \
	'/dev'    \
	'/etc'    \
	'/home'   \
	'/lib'    \
	'/libx32' \
	'/lib32'  \
	'/lib64'  \
	'/media'  \
	'/mnt'    \
	'/opt'    \
	'/root'   \
	'/sbin'   \
	'/srv'    \
	'/usr'    \
	'/var'

# Replace configuration templates
if [ -z "$PARENT" ]; then
	exec_vars L='W' -- walk_paths subst_templates \
				"'$DEST/netctl'"
fi

# Source project specific code
install_sh="$SOURCE/install-sh"
if [ -f "$install_sh" ]; then
	. "$install_sh" "$@" ||
		abort '%s: "%s/install-sh" failed\n' \
			"$prog_name" "$NAME"
fi

exit 0
