#!/usr/bin/env fish
# Pull latest main, build, and run the KVM hello world via make.

set dir (cd (dirname (status filename)) && pwd)

if not test -e /dev/kvm
    echo "/dev/kvm not found - load the module first: sudo modprobe kvm_intel (or kvm_amd)" >&2
    exit 1
end

set repo (git -C $dir rev-parse --show-toplevel 2>/dev/null)
if test -n "$repo"
    git -C $repo pull --ff-only origin main
end

cd $dir
make run
