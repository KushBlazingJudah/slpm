#!/bin/sh
# The worst package manager you'll ever use.

REPO_BASE="$(pwd)/repo"
DATABASE="$(pwd)/db"
LIBC="musl"

is_installed() {
	[ -e "$DATABASE/filelist/$1" ]
}

read_depends() {
	package="$1"
	location="$REPO_BASE/$package"
	depends=""

	if [ ! -e "$location/depends" ]; then
		return
	fi

	printf '%s\n' "$LIBC"

	while read -r line || [ -n "$line" ]; do
		pass1="${line%% *}"
		printf '%s\n' "${pass1%%	*}"
	done < "$location/depends"
}

resolve_depends() {
	package="$1"

	# first pass: get all dependencies
	toplevel="$(read_depends "$package")"
	depends=""
	for dep in $toplevel; do
		resolved="$(resolve_depends "$dep")"
		depends="${depends:+$depends }${resolved:+$resolved }$dep"
	done

	# second pass: remove duplicates, check if we already have them installed, remove
	final=""
	for dep in $depends; do
		case $final in
			*$dep*)
				# do nothing
				;;
			*)
				if ! is_installed "$dep"; then
					final="${final:+$final }$dep"
				fi
				;;
		esac
	done

	printf '%s' "${final}"
}

resolve_depends nano
