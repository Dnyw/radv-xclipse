#!/usr/bin/env python3
"""Package the Bannerlator Wayland build (build-wayland.sh) as one flat zip that both of
Bannerlator's importers accept: the AdrenoTools driver list and the Wayland game-driver list.

usage: package-wayland.py <stage dir> <output dir>

The stage dir holds libvulkan_freedreno_radv.so, libwayland-client.so, libffi.so,
libandroid-support.so, and licenses/ with the Termux packages' license files.
"""
import json
import os
import re
import subprocess
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DRIVER = 'libvulkan_freedreno_radv.so'
LIBS = ['libwayland-client.so', 'libffi.so', 'libandroid-support.so']

EXTRA_NOTICE = """

----------------------------------------------------------------------------------------------------
Bundled libraries
----------------------------------------------------------------------------------------------------

{driver} is the same driver as vulkan.radeon.so in the plain package, built with the Wayland
window-system integration as well. It has the "freedreno" file name only because Bannerlator's
Wayland game-driver importer accepts no other.

libwayland-client.so, libffi.so and libandroid-support.so are unmodified binaries from the Termux
package repository (packages libwayland, libffi and libandroid-support), with their run-time search
path set to their own directory. Their license files from those packages follow.
"""


def git(*args):
    try:
        run = lambda *a: subprocess.run(['git', '-C', ROOT, *a], capture_output=True, text=True,
                                        check=True).stdout.strip()
        # Only this repository's history, never an enclosing one.
        if os.path.normcase(os.path.abspath(run('rev-parse', '--show-toplevel'))) != os.path.normcase(ROOT):
            return ''
        return run(*args)
    except (OSError, subprocess.CalledProcessError):
        return ''


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    stage, out_dir = sys.argv[1], sys.argv[2]
    for name in [DRIVER] + LIBS:
        if not os.path.isfile(os.path.join(stage, name)):
            sys.exit('error: %s is missing in %s' % (name, stage))
    lic_dir = os.path.join(stage, 'licenses')
    licenses = sorted(os.listdir(lic_dir)) if os.path.isdir(lic_dir) else []
    if not licenses:
        sys.exit('error: no license files in %s' % lic_dir)

    mesa_version = open(os.path.join(ROOT, 'VERSION')).read().strip()
    header = open(os.path.join(ROOT, 'include', 'vulkan', 'vulkan_core.h')).read()
    api = re.search(r'VK_HEADER_VERSION_COMPLETE VK_MAKE_API_VERSION\(0, (\d+), (\d+), VK_HEADER_VERSION\)', header)
    patch = re.search(r'#define VK_HEADER_VERSION (\d+)', header)
    vulkan = 'Vulkan %s.%s.%s' % (api.group(1), api.group(2), patch.group(1))

    commit = git('rev-parse', '--short', 'HEAD')
    count = git('rev-list', '--count', 'HEAD') or '1'
    suffix = '-' + commit if commit else ''

    meta = {
        'schemaVersion': 1,
        'name': 'RADV Xclipse Wayland (Mesa %s%s)' % (mesa_version, suffix),
        'description': ('RADV for Samsung Xclipse GPUs, based on Mesa %s, for Bannerlator: import it '
                        'as a GPU driver and as the Wayland game driver.') % mesa_version,
        'author': 'JimVulkan',
        'packageVersion': count,
        'vendor': 'Mesa',
        'driverVersion': vulkan,
        'minApi': 34,
        'libraryName': DRIVER,
    }

    notice = open(os.path.join(ROOT, 'android', 'NOTICE.txt'), encoding='utf-8').read().rstrip('\n')
    notice += EXTRA_NOTICE.format(driver=DRIVER)
    for name in licenses:
        text = open(os.path.join(lic_dir, name), encoding='utf-8', errors='replace').read().rstrip('\n')
        notice += '\n%s\n%s\n\n%s\n' % (name, '-' * len(name), text)

    os.makedirs(out_dir, exist_ok=True)
    zip_path = os.path.join(out_dir, 'radv-xclipse-wayland-%s%s.zip' % (mesa_version, suffix))
    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as z:
        z.writestr('meta.json', json.dumps(meta, indent=2) + '\n')
        for name in [DRIVER] + LIBS:
            z.write(os.path.join(stage, name), name)
        z.writestr('NOTICE.txt', notice + '\n')
    print('packaged %s (%s, %.1f MB)' % (zip_path, vulkan, os.path.getsize(zip_path) / 1e6))


if __name__ == '__main__':
    main()
