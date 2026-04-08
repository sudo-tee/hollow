#!/usr/bin/env bash
set -euo pipefail

# Downloads Windows DLLs from MSYS2 repositories and extracts them to the project root.
#
# This script is designed to work in WSL without requiring an existing MSYS2 installation.
# It downloads .zst packages from MSYS2 mirrors and extracts the required DLLs.
#
# Usage:
#   ./scripts/fetch-windows-dlls.sh              # auto-detect and download

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$SCRIPT_DIR/.."
DEST_DIR="$PROJECT_ROOT"

# MSYS2 mirror URLs
MINGW_MIRROR="https://mirror.msys2.org/mingw/mingw64"
MSYS_MIRROR="https://mirror.msys2.org/msys/x86_64"

echo "[dll-fetch] destination: $DEST_DIR"

# DLLs we need and their package mappings.
# All current non-system runtime deps are statically linked, so this stays empty.
declare -A DLL_TO_PKG
declare -A PKG_TO_MIRROR

# Map DLLs to their packages and mirrors

# Returns 0 if all DLLs are present
all_dlls_present() {
	for dll in "${!DLL_TO_PKG[@]}"; do
		if [[ ! -f "$DEST_DIR/$dll" ]]; then
			return 1
		fi
	done
	return 0
}

# Check if we already have all DLLs
if all_dlls_present; then
	echo "[dll-fetch] all DLLs already present"
	exit 0
fi

# Create temp directory for downloads
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "[dll-fetch] temp directory: $TMPDIR"

# Check for required tools
if ! command -v curl >/dev/null 2>&1; then
	echo "[dll-fetch] error: curl is required but not installed"
	exit 1
fi

# Function to extract a single file from a .tar.zst archive using zstd+tar
extract_from_zst() {
	local archive="$1"
	local filepath="$2"
	local output="$3"

	if command -v zstd >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
		zstd -d -q -c "$archive" | tar -xO "$filepath" >"$output" 2>/dev/null && return 0
	fi
	return 1
}

# Function to download and extract a DLL from a package
download_and_extract() {
	local dll="$1"
	local pkg="${DLL_TO_PKG[$dll]:-}"

	if [[ -z "$pkg" ]]; then
		echo "[dll-fetch] no package mapping for $dll"
		return 1
	fi

	if [[ -f "$DEST_DIR/$dll" ]]; then
		echo "[dll-fetch] $dll already exists, skipping"
		return 0
	fi

	local mirror="${PKG_TO_MIRROR[$pkg]}"
	echo "[dll-fetch] looking for package: $pkg (for $dll)"

	# Try to find the package by listing directory (follow redirects with -L)
	local listing
	listing=$(curl -sSLf "$mirror/" 2>/dev/null || echo "")

	if [[ -z "$listing" ]]; then
		echo "[dll-fetch] failed to list packages from $mirror"
		return 1
	fi

	# Extract package filename
	local pkg_file
	pkg_file=$(echo "$listing" | grep -oE 'href="[^"]*' | grep "$pkg" | sed 's/href="//' | head -n1)

	if [[ -z "$pkg_file" ]]; then
		echo "[dll-fetch] package $pkg not found in mirror"
		return 1
	fi

	# Download the package
	local pkg_url="$mirror/$pkg_file"
	local local_pkg="$TMPDIR/$pkg_file"

	echo "[dll-fetch] downloading: $pkg_url"
	if ! curl -fSL -o "$local_pkg" "$pkg_url"; then
		echo "[dll-fetch] failed to download $pkg_url"
		return 1
	fi

	# Determine the internal path to the DLL
	local dll_path
	if [[ "$pkg" == mingw-w64-x86_64-* ]]; then
		dll_path="mingw64/bin/$dll"
	else
		dll_path="usr/bin/$dll"
	fi

	echo "[dll-fetch] extracting $dll_path from $pkg_file"

	# Try to extract the DLL
	if extract_from_zst "$local_pkg" "$dll_path" "$DEST_DIR/$dll"; then
		chmod +x "$DEST_DIR/$dll" 2>/dev/null || true
		echo "[dll-fetch] extracted $dll"
		return 0
	else
		echo "[dll-fetch] failed to extract $dll from package"
		return 1
	fi
}

# Try to download and extract each missing DLL
missing_dlls=()
for dll in "${!DLL_TO_PKG[@]}"; do
	if [[ ! -f "$DEST_DIR/$dll" ]]; then
		missing_dlls+=("$dll")
	fi
done

echo "[dll-fetch] missing DLLs: ${missing_dlls[*]:-none}"

# Download packages for missing DLLs
for dll in "${missing_dlls[@]}"; do
	download_and_extract "$dll" || echo "[dll-fetch] failed to get $dll"
done

# Check what we got
if all_dlls_present; then
	echo "[dll-fetch] all DLLs successfully fetched"
	exit 0
else
	echo "[dll-fetch] some DLLs are still missing:"
	for dll in "${!DLL_TO_PKG[@]}"; do
		if [[ ! -f "$DEST_DIR/$dll" ]]; then
			echo "  - $dll (package: ${DLL_TO_PKG[$dll]:-unknown})"
		fi
	done
	exit 1
fi
