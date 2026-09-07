#!/usr/bin/env python3
"""Reject embedded subtitle framework wrappers in an app or exported IPA."""

from pathlib import Path, PurePosixPath
import sys
import zipfile


# These dependencies must be linked from static libraries. Framework wrappers
# caused ITMS-90208 when Xcode's generated stubs disagreed with their plists.
FRAMEWORKS = {name + ".framework" for name in (
    "libass", "libfreetype", "libfribidi", "libharfbuzz", "libunibreak",
    "fontconfig", "freetype", "fribidi", "harfbuzz", "libpng",
)}


def validate(product):
    if product.is_dir() and product.suffix == ".app":
        paths = (str(path.relative_to(product)) for path in product.rglob("*"))
    elif product.is_file() and product.suffix == ".ipa":
        with zipfile.ZipFile(product) as archive:
            paths = archive.namelist()
    else:
        raise ValueError(f"Expected an existing .app or .ipa: {product}")
    invalid = sorted({part for path in paths for part in PurePosixPath(path).parts
                      if part.lower() in FRAMEWORKS})
    if invalid:
        raise ValueError("Static subtitle libraries must not be embedded as frameworks: " + ", ".join(invalid))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("Usage: validate-subtitle-packaging.py <app|ipa>")
    try:
        validate(Path(sys.argv[1]))
    except (ValueError, OSError, zipfile.BadZipFile) as error:
        sys.exit(str(error))
    print("PASS: no embedded subtitle framework wrappers")
