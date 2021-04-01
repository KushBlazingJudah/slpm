# SLPM - Shellscript Linux Package Manager
The worst package manager you'll ever use.

This is a package manager written **entirely in POSIX sh**.

**TODO**: write more

## Why?
A long time ago, I wrote a package manager in POSIX sh.
It wasn't great, no, but it worked. And now I want to do it right.

## TODO
- [X] Dependency resolution (should be done)
- [X] Downloading files (and verifying them)
- [X] Building
  - Generates a tarball in current working directory for now.
- [ ] Installing
- [ ] Uninstalling
- [ ] Overwrite protection (hash old/new/current, compare?)
- [ ] Repository syncing
- [ ] Dependency detection (ldd)
- [ ] Finalized package standard
- [ ] Code well commented
- [ ] Able to manage itself
