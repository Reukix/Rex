#!/usr/bin/env python3
import posixpath
import stat
import sys
import unicodedata
import zipfile


MAX_ENTRIES = 200_000
MAX_EXPANDED_BYTES = 8 * 1024 * 1024 * 1024
MAX_SYMLINK_BYTES = 4 * 1024
EXPECTED_EXECUTABLE = "Rex.app/Contents/MacOS/Rex"


def reject(message: str) -> None:
    raise ValueError(message)


def validate_entry_name(raw_name: str) -> str:
    if not raw_name or "\0" in raw_name or "\\" in raw_name or raw_name.startswith("/"):
        reject(f"unsafe archive path: {raw_name!r}")
    name = raw_name[:-1] if raw_name.endswith("/") else raw_name
    if not name:
        reject(f"unsafe archive path: {raw_name!r}")
    components = name.split("/")
    if any(component in ("", ".", "..") for component in components):
        reject(f"unsafe archive path: {raw_name!r}")
    is_app_entry = name == "Rex.app" or name.startswith("Rex.app/")
    is_appledouble_entry = (
        name == "__MACOSX"
        or name == "__MACOSX/Rex.app"
        or name.startswith("__MACOSX/Rex.app/")
    )
    if not is_app_entry and not is_appledouble_entry:
        reject(f"archive entry is outside Rex.app: {raw_name!r}")
    return name


def validate_symlink(archive: zipfile.ZipFile, info: zipfile.ZipInfo, name: str) -> None:
    if info.file_size <= 0 or info.file_size > MAX_SYMLINK_BYTES:
        reject(f"invalid symbolic link size: {name!r}")
    try:
        target = archive.read(info).decode("utf-8")
    except (KeyError, UnicodeDecodeError, RuntimeError) as error:
        reject(f"invalid symbolic link target for {name!r}: {error}")
    if not target or "\0" in target or "\\" in target or target.startswith("/"):
        reject(f"unsafe symbolic link target for {name!r}: {target!r}")
    resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), target))
    if resolved != "Rex.app" and not resolved.startswith("Rex.app/"):
        reject(f"symbolic link escapes Rex.app: {name!r} -> {target!r}")


def validate_archive(path: str) -> None:
    try:
        archive = zipfile.ZipFile(path)
    except (OSError, zipfile.BadZipFile) as error:
        reject(f"invalid update archive: {error}")
    with archive:
        entries = archive.infolist()
        if not entries or len(entries) > MAX_ENTRIES:
            reject(f"invalid update archive entry count: {len(entries)}")

        seen_names: set[str] = set()
        expanded_bytes = 0
        found_executable = False
        found_app_root = False
        for info in entries:
            name = validate_entry_name(info.orig_filename)
            canonical_name = unicodedata.normalize("NFC", name).casefold()
            if canonical_name in seen_names:
                reject(f"duplicate archive path: {name!r}")
            seen_names.add(canonical_name)

            if info.flag_bits & 0x1:
                reject(f"encrypted archive entry: {name!r}")
            expanded_bytes += info.file_size
            if expanded_bytes > MAX_EXPANDED_BYTES:
                reject("expanded update archive is too large")

            mode = (info.external_attr >> 16) & 0xFFFF
            file_type = stat.S_IFMT(mode)
            if stat.S_ISLNK(mode):
                if name.startswith("__MACOSX/"):
                    reject(f"symbolic link is not allowed in AppleDouble metadata: {name!r}")
                validate_symlink(archive, info, name)
            elif file_type not in (0, stat.S_IFREG, stat.S_IFDIR):
                reject(f"unsupported archive entry type: {name!r}")

            if name in ("Rex.app", "__MACOSX", "__MACOSX/Rex.app") and not info.is_dir():
                reject(f"archive root entry is not a directory: {name!r}")
            if name == "Rex.app" and info.is_dir():
                found_app_root = True
            if name == EXPECTED_EXECUTABLE and not stat.S_ISLNK(mode) and not info.is_dir():
                found_executable = True

        if not found_app_root:
            reject("update archive is missing the Rex.app root directory")
        if not found_executable:
            reject(f"update archive is missing {EXPECTED_EXECUTABLE}")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: verify-update-archive.py <Rex-update.zip>")
    try:
        validate_archive(sys.argv[1])
    except ValueError as error:
        print(error, file=sys.stderr)
        raise SystemExit(6) from error


if __name__ == "__main__":
    main()
