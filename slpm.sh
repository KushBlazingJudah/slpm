#!/bin/sh
# The worst package manager you'll ever use.

DATABASE="$(pwd)/db" # $(pwd) is for testing
REPO_BASE="$DATABASE/repo"

TEMP="" # used for when we exit
ERR="" # used for error details

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

get_sources() {
	while IFS='	' read -r link _ _ _; do
		printf '%s\n' "$link"
	done < "$DATABASE/repo/$1/sources"
}

# the next 3 functions share 99% of the same code
get_source_destname() {
	package="$1"
	link="$2"

	# i'm not sure if we should grep here
	while IFS='	' read -r slink destname _ _; do
		if [ "$link" != "$slink" ]; then
			continue
		fi

		if [ -n "$destname" -a "$destname" != "-" ]; then
			printf '%s\n' "$destname"
			return
		fi

		# figure it out ourselves
		protocol="${link%%://*}"
		case $protocol in
			git)
				path="${link##*:}"
				name="${path##*/}"
				printf '%s' "${name%%.git}"
				;;
			#http|https|sftp|ftp)
			*)
				# the following is a terrible idea
				printf '%s' "${link##*/}"
				;;
		esac
		return
	done < "$DATABASE/repo/$package/sources"
}

get_source_hash() {
	package="$1"
	link="$2"

	# i'm not sure if we should grep here
	while IFS='	' read -r slink _ hash _; do
		if [ "$link" = "$slink" ]; then
			printf '%s\n' "$hash"
			return
		fi
	done < "$DATABASE/repo/$package/sources"
}

get_source_size() {
	package="$1"
	link="$2"

	# i'm not sure if we should grep here
	while IFS='	' read -r slink _ _ size; do
		if [ "$link" = "$slink" ]; then
			printf '%d\n' "$size"
			return
		fi
	done < "$DATABASE/repo/$package/sources"
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

download() {
	# usage: download <source> <dest> <hash>
	# TODO: allow using something other than curl

	source="$1"
	dest="$2"
	hash="$3"

	# get a temporary file, download it
	TEMP="$(mktemp -t --suffix=.part slpm.XXXXXX)"
	curl -o "$TEMP" "$source"

	# get hash
	sha=$(sha256sum -b "$TEMP")
	newhash="${sha%% *}"

	# compare it, move if good
	if [ "$newhash" = "$hash" ]; then
		echo "hash OK"
		mv "$TEMP" "$dest"
		return
	fi

	# error out
	ERR="invalid checksum"
	rm "$TEMP"
	TEMP=""
	echo "expected: $hash"
	echo "got: $newhash"
}

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

make_build_env() {
	package="$1"

	TEMP="$(mktemp -d -t slpm_build.XXXX --suffix="$package")"
	mkdir -p "$TEMP"/src
	mkdir -p "$TEMP"/out

	printf '%s' "$TEMP"
}

build() {
	package="$1"
	builddir="$2"
	here="$(pwd)"

	echo "entering build environment"
	(
		cd "$builddir/src"
		echo "extracting archives"

		for file in $(ls --color=never -1 "$builddir/src"); do # sorry
			echo "checking $file"
			[ -e "$file" ] || [ -L "$file" ] || continue
			case "$file" in
				*.tar.bz2)   tar xjf "$file"     ;;
				*.tar.gz)    tar xzf "$file"     ;;
				*.tar.xz)    tar xJf "$file"     ;;
				*.bz2)       bunzip2 "$file"     ;;
				*.rar)       rar x "$file"       ;;
				*.gz)        gunzip "$file"      ;;
				*.tar)       tar xf "$file"      ;;
				*.tbz2)      tar xjf "$file"     ;;
				*.tgz)       tar xzf "$file"     ;;
				*.zip)       unzip "$file"       ;;
				*.Z)         uncompress "$file"  ;;
				*.7z)        7z x "$file"    ;;
				*)           echo "'$file' cannot be extracted via extract()" ;;
			esac
		done

		echo "building"
		PKGSRC="$(pwd)" PKGOUT="$builddir/out" sh -e -- "$REPO_BASE/$package/build"
		if [ "$?" != 0 ]; then
			error "$package" "Build failed!"
			error "$package" "Directory: $builddir"
			exit 1
		fi

		cd "$builddir/out"
		tar -czf "$here/$package.tar.gz" .
	)

	rm -r "$builddir"
}

# main code starts here

# exit on error, disable globbing
set -ef

# set colors if need be
[ "$USE_COLOR" = 1 ] && log_left="\033[1;97m" log_mid="\033[0m\033[0;97m" log_right="\033[0m"

echo
for dep in $(resolve_depends nano) nano; do
	echo "building $dep"
	if is_installed "$dep"; then continue; fi

	builddir="$(make_build_env "$dep")"

	for src in $(get_sources "$dep"); do
		# skip if it's already downloaded
		if [ ! -e "$(get_source_destname "$dep" "$src")" ]; then
			download "$src" "$builddir/out/$(get_source_destname "$dep" "$src")" "$(get_source_hash "$dep" "$src")"
			echo "$ERR"
			if [ -n "$ERR" ]; then
				echo "$ERR"
				error "$ERR"
			fi
		else
			cp -v "$(get_source_destname "$dep" "$src")" "$builddir/src/$(get_source_destname "$dep" "$src")"
		fi
		printf 'downloaded %s\n' "$(get_source_size "$dep" "$link")"
	done

	build "$dep" "$builddir"
done
