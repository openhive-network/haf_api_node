# Install lock wrapper for the app installers

`install_with_app_lock.py` is common-ci-configuration's
`haf-app-tools/scripts/install_with_app_lock.py` at commit
`7658f4893592b132352e5fdbc103dbb9adc7cfa8` (common-ci-configuration#85) with this stack's
refusal message (git blob `4d829f45e6da94ca4005f1a90cd2c086de0578f7`;
`ci/scripts/test-postgrest-app-lock.sh` checks it). When the lock is held, it skips a rerun of
the installed version with exit 0 and fails an upgrade with exit 1. The failure lists, on one
line, the holders the lock function's NOTICE names, and as the recovery stops the app's PostgREST
compose service, which the install service names in `HAF_APP_LOCK_POSTGREST_SERVICE`.

The app images this stack runs carry an older copy, which skips both, and their installers pass
no version. So the install services that record a version mount `with_install_version.py` over
the image's `/usr/local/bin/install_with_app_lock.py` and this copy at
`/usr/local/lib/haf_api_node/install_with_app_lock.py`, and set
`HAF_APP_INSTALLED_VERSION_QUERY`. `with_install_version.py` finds the version the image installs
(`HAF_APP_INSTALL_VERSION_ENV`, else `set_version_in_sql.pgsql` next to `install_app.sh`) and runs
this copy with it. See the README's
[PostgREST servers hold their app's lock](../README.md#postgrest-servers-hold-their-apps-lock).

To move to another revision, copy the file from that commit, carry over the refusal message
(`upgrade_blocked_message`), and update the commit here and the blob in the test.

## hivemind

hivemind's installer is its own (`hive build_schema` / `upgrade_schema`), not this wrapper. In
images without hivemind#456 it skips with exit 0 whenever the lock is held, an upgrade included,
and `hivemind-block-processing` then starts the new code on the old schema and crash-loops. So
`hivemind-install` runs `hivemind_install.sh` as its entrypoint: it runs the image's
`docker_entrypoint.sh`, and when that exits 0 compares the image's revision
(`hive.version.GIT_REVISION`) with `hivemind_app.hive_state.hivemind_git_rev`, which every
hivemind install that runs sets to it. If they differ, the install did not run: it exits 1 with
both revisions, the lock holders the skip NOTICEs name (on one line), and the recovery. Images
with hivemind#456 fail such an install themselves; the check then finds nothing to add.
`ci/scripts/test-hivemind-install-check.sh` tests it.
