#!/usr/bin/env python3
"""Hold a HAF app advisory install lock while running an installer command.

Usage:
    install_with_app_lock.py [--version=VERSION] [--version-query=SQL] APP_NAME DSN CMD [ARG ...]

Tries to acquire the EXCLUSIVE advisory install lock for APP_NAME using DSN
(via hive.try_acquire_app_install_lock from the hive_fork_manager extension).

- If the lock is acquired, runs CMD with ARGs as a subprocess. The lock is
  held for the lifetime of THIS process via the psycopg connection, so all
  sub-step `psql` invocations inside CMD are atomic with respect to BPs.
  The lock is released when this process exits (cleanly, on signal, or on
  crash) because the psycopg connection is dropped.
- If the lock is held by another session (a block-processor or the app's
  PostgREST holding the shared lock), this prints the holder description
  (forwarded from PG NOTICE) and does not run CMD. Whether that skip is an
  exit 0 or a failure depends on the app's version information:

  VERSION (--version, else $HAF_APP_INSTALL_VERSION) is the version CMD
  installs. SQL (--version-query, else $HAF_APP_INSTALLED_VERSION_QUERY) is a
  query whose first column of its first row is the version installed in the
  database, e.g. `SELECT git_hash FROM btracker_app.version`.

  - Both given, and SQL returns VERSION: a rerun of the same version; exit 0
    so docker compose sees `service_completed_successfully`.
  - Both given, and SQL returns another version, NULL or no row, or fails
    because its function, table or schema does not exist (the app is not
    installed): the skip would leave the old schema in place under a new
    image; exit 1 with the recovery steps.
  - Both given, and SQL fails otherwise: the installed version cannot be
    determined; warn and exit 0.
  - Either missing: upgrade detection is off for the app; warn and exit 0.
"""
import logging
import os
import subprocess
import sys

import psycopg2

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)s  install_with_app_lock  %(message)s",
)
log = logging.getLogger(__name__)

_OPTIONS = {
    "--version": ("version", "HAF_APP_INSTALL_VERSION"),
    "--version-query": ("version_query", "HAF_APP_INSTALLED_VERSION_QUERY"),
}
_USAGE = "usage: %s [--version=VERSION] [--version-query=SQL] APP_NAME DSN CMD [ARG ...]"
_EXIT_UPGRADE_BLOCKED = 1


class _NotInstalled(Exception):
    """The installed-version query found no installed version."""


def _first_line(exc: Exception) -> str:
    return str(exc).strip().splitlines()[0] if str(exc).strip() else type(exc).__name__


def forward_notices(conn: "psycopg2.extensions.connection") -> list[str]:
    """Drain conn.notices into the logger and clear the deque; return the forwarded lines."""
    forwarded: list[str] = []
    while conn.notices:
        notice = conn.notices.pop(0).rstrip()
        if notice:
            log.info("%s", notice)
            forwarded.append(notice)
    return forwarded


def _parse_args(argv: list[str]) -> tuple[dict[str, str | None], str, str, list[str]] | None:
    """Split argv into (settings, app_name, dsn, install_cmd); None when it is not a valid call.

    Options are only recognised before APP_NAME, so everything from CMD on reaches CMD as given.
    """
    settings = {name: os.environ.get(env) or None for name, env in _OPTIONS.values()}
    args = list(argv)
    while args and args[0].startswith("--"):
        option, sep, value = args.pop(0).partition("=")
        if option not in _OPTIONS or not sep:
            return None
        settings[_OPTIONS[option][0]] = value or None
    if len(args) < 3:
        return None
    return settings, args[0], args[1], args[2:]


def _installed_version(conn: "psycopg2.extensions.connection", query: str) -> str:
    """Return the version `query` reports; raise _NotInstalled when it reports none."""
    try:
        with conn.cursor() as cur:
            cur.execute(query)
            row = cur.fetchone()
    except (psycopg2.errors.UndefinedFunction,
            psycopg2.errors.UndefinedTable,
            psycopg2.errors.InvalidSchemaName) as exc:
        raise _NotInstalled(_first_line(exc)) from exc
    if row is None or row[0] is None:
        raise _NotInstalled("the query returned no version")
    return str(row[0]).strip()


def _skip_or_fail(conn: "psycopg2.extensions.connection", app_name: str, settings: dict[str, str | None],
                  holder: list[str]) -> int:
    """Exit status of an install that could not take the lock: 0 to skip, non-zero to fail."""
    version = settings["version"]
    query = settings["version_query"]
    if version is None or query is None:
        log.info("Skipping %s install — lock held by an active block-processor.", app_name)
        return 0

    try:
        installed = _installed_version(conn, query)
    except _NotInstalled as exc:
        installed = f"none (not installed: {exc})"
    except psycopg2.Error as exc:
        log.warning("Cannot determine the installed %s version (%s); treating the install as a rerun.",
                    app_name, _first_line(exc))
        log.info("Skipping %s install — lock held by an active block-processor.", app_name)
        return 0
    else:
        if installed == version:
            log.info("Skipping %s install — version %s is already installed and the lock is held "
                     "by an active block-processor.", app_name, version)
            return 0

    log.error(
        "Cannot install %s version %s: the installed version is %s, and the install lock is held by "
        "%s. Skipping would leave the old version serving under the new image. To upgrade: stop "
        "%s-postgrest and any other holder of the lock, rerun the install, then start them again.",
        app_name, version, installed, "; ".join(holder) or "another session (no holder reported)",
        app_name,
    )
    return _EXIT_UPGRADE_BLOCKED


def main():
    parsed = _parse_args(sys.argv[1:])
    if parsed is None:
        log.error(_USAGE, sys.argv[0])
        return 2
    settings, app_name, dsn, install_cmd = parsed

    if settings["version"] is None or settings["version_query"] is None:
        log.warning(
            "No --version/HAF_APP_INSTALL_VERSION and --version-query/HAF_APP_INSTALLED_VERSION_QUERY "
            "for %s; upgrade detection is off, so an upgrade blocked by a held lock is skipped "
            "as a rerun would be.",
            app_name,
        )

    conn = psycopg2.connect(dsn)
    conn.autocommit = True

    try:
        with conn.cursor() as cur:
            cur.execute("SET application_name = %s", (f"{app_name}-install",))
            cur.execute("SELECT hive.try_acquire_app_install_lock(%s)", (app_name,))
            acquired = cur.fetchone()[0]
    except psycopg2.errors.UndefinedFunction:
        # The hive_fork_manager extension in this database predates the
        # advisory-lock helpers (added in haf MR !970). Run the install
        # without the lock rather than refusing to proceed -- the lock is a
        # safety mechanism, not a correctness requirement. This is the
        # Python-side counterpart of install_app.sh's "wrapper not found"
        # graceful skip; both make the lock layer optional so the install
        # remains functional across haf version skews.
        log.warning(
            "hive.try_acquire_app_install_lock not defined in this database; "
            "running %s install without HAF advisory lock. "
            "(Expected only against a haf version that predates the helpers; "
            "should not happen in a current production stack.)",
            app_name,
        )
        conn.close()
        result = subprocess.run(install_cmd)
        return result.returncode

    # Forward the NOTICE from the function (the holder description, on failure)
    holder = forward_notices(conn)

    if not acquired:
        try:
            return _skip_or_fail(conn, app_name, settings, holder)
        finally:
            conn.close()

    log.info("Acquired install lock for %s; running install command.", app_name)
    try:
        result = subprocess.run(install_cmd)
        return result.returncode
    finally:
        # Closing the connection releases the session-scoped advisory lock.
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
