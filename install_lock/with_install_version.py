#!/usr/bin/env python3
"""Run the pinned install_with_app_lock.py with the version the app's installer installs.

Mounted over an app image's /usr/local/bin/install_with_app_lock.py, under which the app's
install_app.sh re-executes itself as `install_with_app_lock.py APP_NAME DSN CMD [ARG ...]`.

The wrapper (install_with_app_lock.py next to this file, mounted at _WRAPPER) fails an install
that a held lock would skip as an upgrade only when it has the version CMD installs
(HAF_APP_INSTALL_VERSION) and a query of the installed one (HAF_APP_INSTALLED_VERSION_QUERY, set
on the compose service). The installers pass neither, so unless HAF_APP_INSTALL_VERSION is set
this takes it from the image: the environment variable HAF_APP_INSTALL_VERSION_ENV names, else
the git hash in the set_version_in_sql.pgsql next to CMD. With no version found the wrapper runs
without upgrade detection and logs that.
"""
import os
import re
import sys

_WRAPPER = "/usr/local/lib/haf_api_node/install_with_app_lock.py"
_GIT_HASH = re.compile(r"'([0-9a-f]{40})'")


def _image_version(cmd: str) -> str | None:
    name = os.environ.get("HAF_APP_INSTALL_VERSION_ENV")
    if name:
        return os.environ.get(name) or None
    try:
        with open(os.path.join(os.path.dirname(cmd), "set_version_in_sql.pgsql"), encoding="utf-8") as f:
            match = _GIT_HASH.search(f.read())
    except FileNotFoundError:
        return None
    return match.group(1) if match else None


def main() -> None:
    args = sys.argv[1:]
    # The wrapper's own options come before APP_NAME; CMD follows APP_NAME and DSN.
    positional = args[next((i for i, a in enumerate(args) if not a.startswith("--")), len(args)):]
    if len(positional) >= 3 and not os.environ.get("HAF_APP_INSTALL_VERSION"):
        version = _image_version(positional[2])
        if version:
            os.environ["HAF_APP_INSTALL_VERSION"] = version
    os.execv(sys.executable, [sys.executable, _WRAPPER, *args])


if __name__ == "__main__":
    main()
