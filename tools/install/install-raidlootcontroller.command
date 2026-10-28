#!/bin/bash
# Raid Loot Controller installer and updater for WoW: Forever.
# macOS: open Terminal and run:  bash ~/Downloads/install-raidlootcontroller.command
# (or chmod +x it once and double-click). Linux (Wine, Lutris): same, with bash.
# Re-run it to update. Usage: install-raidlootcontroller.command [WoW folder] [local zip]
set -u

URL='https://github.com/powerfulqa/RaidLootController/releases/latest/download/RaidLootController.zip'
ADDON='RaidLootController'
WOW_PATH="${1:-}"
ZIP_PATH="${2:-}"

finish() {
	if [ -t 0 ] && [ -z "${RLC_NO_PAUSE:-}" ]; then
		read -r -p 'Press Enter to close' _
	fi
	exit "$1"
}

# A game folder has the game in it: an .app on macOS, a Wow*.exe under Wine.
is_game_dir() {
	local f
	for f in "$1"/*.app "$1"/Wow*.exe "$1"/WoW*.exe; do
		[ -e "$f" ] && return 0
	done
	return 1
}

# 1 = Forever for sure, 2 = beta name only, 0 = not Forever.
# .flavor.info names the product ("wowf" is Forever); when present it wins.
forever_rank() {
	if [ -f "$1/.flavor.info" ]; then
		tr -d '\r' <"$1/.flavor.info" | grep -qx 'wowf' && echo 1 || echo 0
		return
	fi
	case "$(basename "$1")" in
	_forever_) echo 1 ;;
	_classic_beta_) echo 2 ;;
	*) echo 0 ;;
	esac
}

SURE=()
GUESS=()
add_flavors() {
	local root="${1%/}" d r c
	[ -d "$root" ] || return 0
	for d in "$root" "$root"/_*_; do
		[ -d "$d" ] || continue
		r=$(forever_rank "$d")
		[ "$r" != 0 ] && is_game_dir "$d" || continue
		for c in ${SURE[@]+"${SURE[@]}"} ${GUESS[@]+"${GUESS[@]}"}; do
			[ "$c" = "$d" ] && continue 2
		done
		if [ "$r" = 1 ]; then SURE+=("$d"); else GUESS+=("$d"); fi
	done
}

if [ -n "$WOW_PATH" ]; then
	add_flavors "$WOW_PATH"
else
	echo 'Looking for WoW: Forever...'
	for root in "/Applications/World of Warcraft" "$HOME/Applications/World of Warcraft" \
		"$HOME/Games/battlenet/drive_c/Program Files (x86)/World of Warcraft" \
		"$HOME/Games/world-of-warcraft/drive_c/Program Files (x86)/World of Warcraft" \
		"$HOME/.wine/drive_c/Program Files (x86)/World of Warcraft"; do
		add_flavors "$root"
	done
fi

while :; do
	if [ ${#SURE[@]} -gt 0 ]; then
		CAND=("${SURE[@]}")
	elif [ ${#GUESS[@]} -gt 0 ]; then
		CAND=("${GUESS[@]}")
	else
		CAND=()
	fi
	[ ${#CAND[@]} -gt 0 ] && break
	echo 'Could not find WoW: Forever.'
	echo 'In Battle.net, pick WoW: Forever, click the gear, then Show in Finder (or Explorer).'
	read -r -p 'Paste that folder path here (or press Enter to quit): ' p || finish 1
	p="${p%\"}"
	p="${p#\"}"
	p="${p%/}"
	[ -n "$p" ] || finish 1
	add_flavors "$p"
	# The pasted folder may be the Forever folder of an unknown name.
	if [ ${#SURE[@]} -eq 0 ] && [ ${#GUESS[@]} -eq 0 ]; then
		if [ -d "$p" ] && is_game_dir "$p"; then SURE+=("$p"); else echo 'No game found there.'; fi
	fi
done

if [ ${#CAND[@]} -eq 1 ]; then
	GAME="${CAND[0]}"
else
	echo 'Found more than one WoW: Forever folder:'
	for i in "${!CAND[@]}"; do echo "  $((i + 1)). ${CAND[$i]}"; done
	while :; do
		read -r -p "Type a number (1-${#CAND[@]}): " n || finish 1
		case "$n" in '' | *[!0-9]*) continue ;; esac
		if [ "$n" -ge 1 ] && [ "$n" -le ${#CAND[@]} ]; then
			GAME="${CAND[$((n - 1))]}"
			break
		fi
	done
fi
echo "Game folder: $GAME"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/rlc-install.XXXXXX") || finish 1
trap 'rm -rf "$TMP"' EXIT

fail() {
	echo "Install failed: $1"
	echo 'Close the game and try again, or install the zip by hand.'
	finish 1
}

if [ -n "$ZIP_PATH" ]; then
	ZIP="$ZIP_PATH"
else
	echo 'Downloading the latest version...'
	ZIP="$TMP/$ADDON.zip"
	curl -fsSL --proto '=https' --tlsv1.2 -o "$ZIP" "$URL" || fail 'download failed.'
fi
unzip -q "$ZIP" -d "$TMP/unzipped" || fail 'could not unzip the download.'
SRC="$TMP/unzipped/$ADDON"
[ -f "$SRC/$ADDON.toc" ] || fail "the download is not a Raid Loot Controller zip ($ADDON.toc missing)."
VER=$(sed -n 's/^## Version:[[:space:]]*//p' "$SRC/$ADDON.toc" | tr -d '\r' | head -n 1)

# Copy beside the old folder first, so a failed copy leaves the old one working.
ADDONS="$GAME/Interface/AddOns"
DEST="$ADDONS/$ADDON"
mkdir -p "$ADDONS" || fail "cannot write to $ADDONS"
rm -rf "$DEST.new"
cp -R "$SRC" "$DEST.new" || fail "cannot write to $ADDONS"
UPDATED=
[ -d "$DEST" ] && UPDATED=1
rm -rf "$DEST" || fail "cannot remove the old $DEST" # stale files go; WTF is never touched
mv "$DEST.new" "$DEST" || fail "cannot rename $DEST.new"

if [ -n "$UPDATED" ]; then echo "Updated Raid Loot Controller $VER."; else echo "Installed Raid Loot Controller $VER."; fi
echo "Folder: $DEST"
echo 'If the game is open, type /reload in chat. Your settings are kept.'
finish 0
