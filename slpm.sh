#!/bin/sh
# The worst package manager you'll ever use.

ROOT="$(pwd)/root"
DATABASE="$ROOT/var/db/slpm" # $(pwd) is for testing
REPO_BASE="$DATABASE/repo"

TEMP="" # used for when we exit
ERR="" # used for error details

# TODO: phase out in favour of a file that lists packages that every package
# should expect
#ESSENTIALS="musl"

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
	read -r line < "$REPO_BASE/$1/version"
	printf '%s' "$line"
}

get_installed_version() {
	# lets just grep $DATABASE/state
	# i wish i could escape $1 but i'm not trying
	result=$(grep "^$1" < "$DATABASE/state" ||:)

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

		if [ -n "$destname" ] && [ "$destname" != "-" ]; then
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

check_owner_of() {
	# usage: check_owner_of <file>
	# gets the owner of a file, or returns nothing if there is none
	file="$1"

	set +f
	for pkg in "$DATABASE"/filelist/*; do
		result="$(grep "^$file:" "$pkg" ||:)"
		if [ -n "$result" ]; then
			printf '%s' "$pkg"
			return
		fi
	done
	set -f
}

get_packaged_hash() {
	# usage: get_packaged_hash <file>
	# gets the hash to a file according to the current database
	# this hash is always whatever it was when we installed it

	file="$1"

	set +f
	for pkg in "$DATABASE"/filelist/*; do
		result="$(grep "^$file:" "$pkg" ||:)"
		if [ -n "$result" ]; then
			# we could do this better
			IFS=":" read -r file hash perms owner group <<EOF
$result
EOF
			printf '%s' "$hash"
			return
		fi
	done
	set -f
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
	sha=$(sha1sum -b "$TEMP")
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
	version=$(get_version "$package")

	echo "entering build environment"
	(
		cd "$builddir/src"
		echo ">>> Extracting archives..."

		# enable globs temporarily
		set +f
		for file in *; do
			[ -e "$file" ] || [ -L "$file" ] || continue
			# this is a beautiful function that i stole from my .profile
			# it was stolen earlier from somewhere else
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
				*)           ;; # fail quietly
			esac
		done
		set -f

		echo ">>> Building..."
		PKGSRC="$(pwd)" PKGOUT="$builddir/out" sh -e -- "$REPO_BASE/$package/build"

		cd "$builddir/out"

		# strip binaries if "$builddir/nostrip" doesn't exist
		if [ ! -e "$builddir/nostrip" ]; then
			find usr/lib -type f -name "*.a" \
				-exec strip --strip-debug {} ';' 2>/dev/null

			find lib usr/lib -type f -name "*.so*" ! -name "\*dbg" \
				-exec strip --strip-unneeded {} ';' 2>/dev/null

			find bin sbin usr/bin usr/sbin usr/libexec -type f \
				-exec strip --strip-all {} ';' 2>/dev/null

			find usr/lib usr/libexec -name "*.la" -delete 2>/dev/null
		fi

		# make .manifest
		# tl;dr hash all files, save permissions
		echo ">>> Creating manifest..."

		dohash() {
			find . -mindepth 1 -type f | while read -r line; do
				file="${line##./}"
				_hash="$(sha1sum -b "$file")"
				hash="${_hash%% *}"

				# this is probably overengineered
				perms="$(stat -c %a "$file")"
				owner="$(stat -c %u "$file")"
				group="$(stat -c %g "$file")"

				printf '%s:%s:%s:%s:%s\n' "$file" "$hash" "$perms" "$owner" "$group"
			done

			# get all directories
			find . -mindepth 1 -type d | while read -r line; do
				file="${line##./}"

				# this is probably overengineered
				perms="$(stat -c %a "$file")"
				owner="$(stat -c %u "$file")"
				group="$(stat -c %g "$file")"

				printf '%s:d:%s:%s:%s\n' "$file" "$perms" "$owner" "$group"
			done
		}

		# lol
		dohash | sed '/^\./d' > "$builddir"/out/.manifest

		# make .info file
		echo "$package $version" > .info

		tar -czf "$here/$package-$version.tar.gz" .
	) || {
		error "$package" "Build failed!"
		error "$package" "Directory: $builddir"
		exit 1
	}

	rm -r "$builddir"
}

remove_package_files() {
	# usage: remove_package_files <package>
	# removes all files if not modified, deletes empty directories
	# TODO: recursively delete empty directories
	# that was the aim of the recursion hack but doesn't work well enough

	while IFS=":" read -r file hash perms owner group; do
		if [ "$hash" = "d" ]; then
			rmdir "$ROOT"/"$file" 2>/dev/null ||:
			continue
		fi

		_hash="$(sha1sum -b "$ROOT/$file" 2>/dev/null ||:)"
		thash="${_hash%% *}"

		if [ "$hash" = "$thash" ]; then
			# not modified
			rm -f "$ROOT"/"$file" ||:
		elif [ "$2" != "1" ]; then
			echo "skipping $file (modified)"
		fi
	done < "$DATABASE"/filelist/"$1"

	if [ "$2" = "1" ]; then return; fi
	remove_package_files "$1" 1
}

install_package() {
	# usage: install_package <path to tarball>
	package_tar="$1"

	if [ ! -e "$1" ]; then
		ERR="file doesn't exist"
		return
	fi

	# get a temporary directory
	TEMP="$(mktemp -d -t --suffix=-"$package_tar" slpm.XXXXXX)"

	# extract to it
	tar -xpf "$package_tar" -C "$TEMP"

	# read some basic info
	package=""
	version=""
	IFS=" " read -r package version < "$TEMP/.info"

	# lets verify hashes, check for conflicts
	# we aren't dealing with files that aren't in the manifest, we don't copy them anyway
	badhashes=""
	conflicts=""
	notfound=""
	while IFS=":" read -r file hash perms owner group; do
		# TODO: this could go outside of where we want it to be
		if [ "$hash" = "d" ]; then continue; fi

		if [ -e "$TEMP/$file" ]; then
			_hash="$(sha1sum -b "$TEMP/$file")"
			thash="${_hash%% *}"
			if [ "$thash" != "$hash" ]; then
				echo "$file: hashes don't match"
				echo "expected: $hash"
				echo "got: $thash"
				badhashes="${badhashes:+$badhashes }$file"
				echo
			fi

			if [ -e "$ROOT/$file" ]; then
				# TODO: protect files from $ESSENTIALS, some etc files like passwd

				# if it's the same, check if someone else owns it
				owner="$(check_owner_of "$file")"
				if [ -n "$owner" ] && [ "$owner" != "$package" ]; then
					echo "$file: owned by $owner"

					case ${ESSENTIALS:-"-"} in
						*$owner*)
							echo "...which is an essential package."
							echo "quitting while we're ahead"
							ERR="$file is from essential package $owner"
							return
							;;
					esac
				fi


				# TODO: skip over this if it's owned by another package
				# check if it's the same
				_ehash="$(sha1sum -b "$ROOT"/"$file")"
				ehash="${_ehash%% *}"

				# otherwise, error
				oldhash="$(get_packaged_hash "$file")"
				if [ "$oldhash" != "$ehash" ]; then
					# this is where the threesome of files come in
					# if current != old, ask if we should choose current or new
					# but that is TODO
					echo "$file: exists on disk, hashes differ"
					echo "old hash: $oldhash"
					echo "current hash: $ehash"
					echo "new hash: $thash"
					ERR="hash mismatch on $file"
					return
				fi
			fi
		else
			# TODO: file doesn't exist
			echo "$file: doesn't exist"
			notfound="${notfound:+$notfound }$file"
		fi
	done < "$TEMP"/.manifest

	# lets move files
	# create directories first
	while IFS=":" read -r file hash perms owner group; do
		if [ "$hash" = "d" ] && [ ! -d "$ROOT"/"$file" ]; then
			mkdir "$ROOT"/"$file"
			chmod "$perms" "$ROOT"/"$file"
			chown "$owner" "$ROOT"/"$file"
			chgrp "$group" "$ROOT"/"$file"
		fi
	done < "$TEMP"/.manifest

	# move files
	while IFS=":" read -r file hash perms owner group; do
		if [ "$hash" != "d" ]; then
			# TODO: we don't check if files collide here
			mv -vf "$TEMP"/"$file" "$ROOT"/"$file"
			chmod "$perms" "$ROOT"/"$file"
			chown "$owner" "$ROOT"/"$file"
			chgrp "$group" "$ROOT"/"$file"
		fi
	done < "$TEMP"/.manifest

	if is_installed "$package"; then
		# remove old files
		remove_package_files "$package"

		# >inb4 don't repeat yourself
		tar -xpf "$package_tar" -C "$TEMP" 2>/dev/null ||:

		# lets move files
		# create directories first
		while IFS=":" read -r file hash perms owner group; do
			if [ "$hash" = "d" ] && [ ! -d "$ROOT"/"$file" ]; then
				mkdir "$ROOT"/"$file"
				chmod "$perms" "$ROOT"/"$file"
				chown "$owner" "$ROOT"/"$file"
				chgrp "$group" "$ROOT"/"$file"
			fi
		done < "$TEMP"/.manifest

		# move files
		while IFS=":" read -r file hash perms owner group; do
			if [ "$hash" != "d" ]; then
				# TODO: we don't check if files collide here
				mv -vf "$TEMP"/"$file" "$ROOT"/"$file"
				chmod "$perms" "$ROOT"/"$file"
				chown "$owner" "$ROOT"/"$file"
				chgrp "$group" "$ROOT"/"$file"
			fi
		done < "$TEMP"/.manifest
	fi

	cp -v "$TEMP"/.manifest "$DATABASE"/filelist/"$package"
	sed -i "/^$package/d" "$DATABASE"/state ||:
	echo "$package $version" >> "$DATABASE"/state

	rm -rf "$TEMP"
	TEMP=""
}

remove_package() {
	# usage: remove_package <package>
	# removes a package

	if is_installed "$1"; then
		remove_package_files "$1"
		rm -f "$DATABASE"/filelist/"$1"
		sed -i "/^$1*$/d" "$DATABASE"/state
	fi
}

download_sources() {
	for src in $(get_sources "$1"); do
		# skip if it's already downloaded
		if [ ! -e "$(get_source_destname "$1" "$src")" ]; then
			protocol="${src%%://*}"
			if [ "$protocol" = "local" ]; then
				cp -v "$REPO_BASE"/"$1"/"${src##local://}" "$builddir/src/$(get_source_destname "$1" "$src")"
			else
				download "$src" "$builddir/src/$(get_source_destname "$1" "$src")" "$(get_source_hash "$1" "$src")"
				if [ -n "$ERR" ]; then
					error "$1" "Failed to download sources: $ERR"
					ERR=""
					return
				fi
			fi
		else
			cp -v "$(get_source_destname "$1" "$src")" "$builddir/src/$(get_source_destname "$1" "$src")"
		fi
		printf 'downloaded %s\n' "$(get_source_size "$1" "$link")"
	done
}

build_from_scratch() {
	# usage: build_from_scratch <package> <force ? 1 : undefined>

	echo "building $1"
	if is_installed "$1" && [ "$2" != "1" ]; then return; fi

	builddir="$(make_build_env "$1")"

	download_sources "$1"

	build "$1" "$builddir"
}

# main code starts here

# exit on error, disable globbing
set -ef

# set colors if need be
[ "$USE_COLOR" = 1 ] && log_left="\033[1;97m" log_mid="\033[0m\033[0;97m" log_right="\033[0m"

operation="$1"
shift 1

case $operation in
	i|install)
		install_package "$1"
		;;
	u|r|remove|uninstall)
		remove_package "$1"
		;;
	b|build)
		for dep in $(resolve_depends "$1"); do
			build_from_scratch "$dep"

			install_package "$dep-$(get_version "$dep").tar.gz"
			if [ -n "$ERR" ]; then
				error "$ERR"
				return 1
			fi
		done
		build_from_scratch "$1"
		if [ -n "$ERR" ]; then
			error "$ERR"
			return 1
		fi
		;;
	I|build-install)
		for dep in $(resolve_depends "$1") "$1"; do
			build_from_scratch "$dep"

			install_package "$dep-$(get_version "$dep").tar.gz"
			if [ -n "$ERR" ]; then
				error "$ERR"
				exit 1
			fi
		done
		;;
	*)
		cat <<EOF
         __
   _____/ /___  ____ ___
  / ___/ / __ \\/ __ \`__ \\  slpm
 (__  ) / /_/ / / / / / /  it's simply not good
/____/_/ .___/_/ /_/ /_/   https://github.com/KushBlazingJudah/slpm
      /_/

options:
	i|install <tarball>:	install a package
	I|build-install <pkg>:	build and install a package
	u|uninstall <pkg>:	uninstall a package
	b|build <pkg>:		build a package
EOF
esac
