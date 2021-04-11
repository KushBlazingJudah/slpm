# SLPM - Shellscript Linux Package Manager
The worst package manager you'll ever use.

This is a package manager written **entirely in POSIX sh**.
It might work in fully POSIX environments, it might not.

Either way, it works on my machine.

## Why?
A long time ago, I wrote a package manager in POSIX sh.
It wasn't great, no, but it worked. And now I want to do it right.

## How to set it up
`slpm` is still in a quite early stage but can be set up somewhat by creating a
few folders.

Namely, run `mkdir -p root/var/db/slpm/repo && mkdir -p root/var/db/slpm/filelist`
and then `touch root/var/db/slpm/state`.

Follow the section on how to create packages to create packages, and throw them
into `root/var/db/slpm/repo` for it to work.

You can then do one of 4 things as of writing:
- `./slpm.sh b <package>` to build a package
  - Might work.
  - Outputs a tarball in the directory `slpm` was executed in.
- `./slpm.sh I <package>` to build and then install a package
  - Like `b`, it dumps its tarballs where you ran it.
- `./slpm.sh i <tarball>` to install a tarball that was previously built
- `./slpm.sh u <package>` to uninstall a package.
  - Doesn't always work but sometimes it does.

## How to create packages
Packages are very simple to create.

Say you want to port over `zlib`.
You build `zlib` by running `./configure`, `make`, and `make install`, so create
a `build` file which is an executable shell script.
This is the most complicated part.

```sh
#!/bin/sh

cd zlib-1.2.11
./configure --prefix=/usr
make
make DESTDIR="$PKGOUT" install
```

We're targeting version `1.2.11`, so let's `echo "1.2.11" > version`.

We need some sources, so let's make a `sources` file.
The format is made up like this:
```
url	destination name (use "-" for autodetect)	sha256 hash	filesize (optional right now)
```
The spaces in between the entries aren't actually spaces, they're tabs.

With that in mind, we could make a `sources` file for `zlib` like this:
```
https://www.zlib.net/zlib-1.2.11.tar.xz	-	4ff941449631ace0d4d203e3483be9dbc9da454084111f97ea0a2114e19bf066	467960
```

And now we're done.
You can build and install this package, as long as the `build` script is executable and works.

If your package has any dependencies, you can list them line-by-line in `depends`.

## TODO
- [X] Dependency resolution (should be done)
- [X] Downloading files (and verifying them)
- [X] Building
  - Generates a tarball in current working directory for now.
  - Environment is extremely leaky.
- [X] Installing
- [X] Uninstalling
- [ ] Overwrite protection (hash old/new/current, compare?)
  - Almost done, we check for it but error out if it fails.
- [ ] Repository syncing
- [ ] Cleanup & refactor
  - Make it look nice, both in the terminal and in the script.
- [ ] Packages with a lot of files take **forever** to generate a manifest for. Speed it up.
  - Try packaging Linux, and go for lunch when it's generating a manifest. It *might* be done then.
  - Possible methods include: "multithreading", faster hashing algorithm other than sha1
  - Could also just defer it to installation
- [X] Local sources from repository (for patches and the like)
- [ ] Dependency detection (ldd)
- [X] Strip binaries
- [ ] Finalized package standard
  - The package standard is largely done and what's there will probably not change.
  However, there are still more things that need to be done.
- [ ] Database locking
- [ ] Code well commented
- [ ] Able to manage itself
