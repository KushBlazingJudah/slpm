#!/bin/sh
# The worst package manager you'll ever use.

DATABASE="$(pwd)/db" # $(pwd) is for testing
REPO_BASE="$DATABASE/repo"

# TODO: phase out in favour of a file that lists packages that every package
# should expect
ESSENTIALS="musl"

# { Logging
log_left=""
log_mid="->\t"
log_right=""
log () {
	# usage: log <left column> <message>
	# goes to stderr
	printf "%b%s%b%s%b\n" "$log_left" "$1" "$log_mid" "$2" "$log_right" >&2
}

info () {
	log "info" "$@"
}

error () {
	log "error" "$@"
}
# }

# { Package information
is_installed() {
	# the easiest way to do this is to check if it's in the file list
	[ -e "$DATABASE/filelist/$1" ]
}

is_package() {
	# see if it exists in $DATABASE/repo
	[ -d "$DATABASE/repo/$1" ]
}

get_version() {
	# lets just grep $DATABASE/state
	# i wish i could escape $1 but i'm not trying
	result=$(grep "^$1" < "$DATABASE/state")

	# remove everything before the space
	printf '%s' "${result##* }"
}

read_depends() {
	package="$1"
	location="$REPO_BASE/$package"
	depends=""

	# every package is guarenteed to depend on $ESSENTIALS
	printf '%s\n' "$ESSENTIALS"

	# just stop here if there's no dependencies
	# assume it wants $ESSENTIALS and quit
	if [ ! -e "$location/depends" ]; then
		return
	fi

	# lets read the dependency file
	while read -r line || [ -n "$line" ]; do
		pass1="${line%% *}" # discard everything after a space

		# same thing but with tabs, and we print it
		printf '%s\n' "${pass1%%	*}"
	done < "$location/depends"
}
# }

resolve_depends() {
	package="$1"

	# return if this is an essential package
	# it WILL result in an infinite loop
	case $ESSENTIALS in
		*$package*)
			return
			;;
	esac

	# first pass: get all dependencies
	toplevel="$(read_depends "$package")"
	depends=""
	for dep in $toplevel; do
		resolved="$(resolve_depends "$dep")"

		# i would use the ${VAR:+string} syntax but we're processing it
		# later, so we don't need to
		depends="$depends $resolved $dep"
	done

	# second pass: remove duplicates, check if we already have them
	# installed, and remove them if we do
	# otherwise just add it to the list
	final=""
	for dep in $depends; do
		case $final in
			*$dep*)
				# do nothing
				;;
			*)
				# add to list if it's not installed
				if ! is_installed "$dep"; then
					# this is the magical :+ syntax i was
					# talking about earlier
					# it allows us to join strings in an
					# intuitive way
					final="${final:+$final }$dep"
				fi
				;;
		esac
	done

	printf '%s' "${final}"
}

# main code starts here

# exit on error
set -e

# set colors if need be
[ "$USE_COLOR" = 1 ] && log_left="\033[1;97m" log_mid="\033[0m\033[0;97m" log_right="\033[0m"
resolve_depends nano
