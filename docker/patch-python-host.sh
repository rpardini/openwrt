#!/usr/bin/env bash

# Work around a python3 host-build breakage in the packages feed.
# Feed commit d883c02a ("python3: pin host curses to the SDK's narrow ncurses") forces every curses
# header check in CPython's configure to "no", but it also added ncurses/host to HOST_BUILD_DEPENDS -
# so pkg-config still finds hostpkg's ncursesw and configure still enables the _curses module.
# Include/py_curses.h then includes no curses header at all (all its HAVE_*CURSES*_H are off) and
# Modules/_cursesmodule.c fails to compile, taking the whole PGO host build down with it.
# The host python has no use for curses, so disable the modules outright - the same way the feed
# already disables _tkinter.
# The Dockerfile runs this after the toolchain and kernel builds on purpose, so applying it does not
# invalidate those (expensive) cached layers. Idempotent.
#
# Usage (in the tree root): docker/patch-python-host.sh

set -o errexit -o pipefail -o nounset

declare py3_makefile="feeds/packages/lang/python/python3/Makefile"
if grep -q 'py_cv_module__curses' "${py3_makefile}"; then
	echo "python3 feed already disables _curses for the host build; nothing to do"
else
	grep -q 'py_cv_module__tkinter=n/a' "${py3_makefile}" || { echo "python3 feed Makefile no longer has the expected anchor, curses workaround needs a look" >&2; exit 1; }
	sed -i 's|py_cv_module__tkinter=n/a|py_cv_module__tkinter=n/a \\\n\tpy_cv_module__curses=n/a \\\n\tpy_cv_module__curses_panel=n/a|' "${py3_makefile}"
fi
grep -n -A 4 '^HOST_CONFIGURE_VARS' "${py3_makefile}"
