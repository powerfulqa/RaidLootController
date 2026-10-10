#!/bin/sh
# Copy the shared kit (RLC_Kit.lua) to WoWClearance, or with --check, fail
# if the two copies differ. WoWClearance's repo sits next to this one.
set -e
here=$(dirname "$0")/..
there=${WC_DIR:-$here/../WoWClearance}
if [ "$1" = "--check" ]; then
    cmp "$here/RLC_Kit.lua" "$there/WoWClearance_Kit.lua" && echo "kit in sync"
else
    cp "$here/RLC_Kit.lua" "$there/WoWClearance_Kit.lua" && echo "kit copied to $there"
fi
