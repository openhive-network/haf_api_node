#!/usr/bin/env bash
# The step functions are called indirectly, through `step`.
# shellcheck disable=SC2317
# The checks AIDEV's verification slots run (.aidev/project.yaml), as one junit
# report per suite: each named step is a test case, its log the failure body.
#
#   .aidev/run-checks.sh <suite> <step>...
#
#   - compose-lint    dclint on every compose file, with the rules and globs of CI's
#                     lint-docker-compose job
#   - shellcheck      ShellCheck as the lint-shellcheck CI job runs it (the agent-check
#                     scripts in healthchecks/), plus the scripts under .aidev/
#   - log-rotation    log_rotation/sync_log_rotation.py --check (CI's check-log-rotation)
#   - caddy-validate  caddy/Caddyfile.tmpl rendered the way caddy/entrypoint.sh does,
#                     under each environment in CADDY_VARIANTS below, then
#                     `caddy validate`; one junit case per variant
#   - caddy-smoke     caddy serving the rendered template with stub upstreams; one junit
#                     case per route checked (.aidev/caddy_smoke.py)
#
# Reports go to test-results/<suite>/: junit.xml (one case per step) plus
# caddy-validate.xml and caddy-smoke.xml.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

suite="${1:?usage: $0 <suite> <step>...}"; shift
out="test-results/$suite"
rm -rf "$out"; mkdir -p "$out"
cases="$out/cases.tsv"; : > "$cases"

status=0
# record CASES_FILE NAME RC SECONDS LOG
record() {
    if [ "$3" -eq 0 ]; then
        printf 'case\t%s\tpass\t%s\t\n' "$2" "$4" >> "$1"
    else
        printf 'case\t%s\tfail\t%s\texit %s\t%s\n' "$2" "$4" "$3" "$5" >> "$1"
    fi
}

step() {
    local name="$1"; shift
    local log="$out/$name.log" t0=$SECONDS rc=0
    echo "== $name" >&2
    "$@" > "$log" 2>&1 < /dev/null || rc=$?
    [ "$rc" -eq 0 ] || { status=1; tail -40 "$log" >&2; }
    record "$cases" "$name" "$rc" "$((SECONDS - t0))" "$log"
}

compose_lint() {
    # The same file set and rules as .gitlab-ci.yml's lint-docker-compose (`**` is
    # an ordinary `*` there, as here without globstar).
    dclint ./*.yaml ci/compose.yml ./**/compose*.yml \
        --disable-rule service-keys-order \
        --disable-rule top-level-properties-order \
        --disable-rule services-alphabetical-order \
        --disable-rule require-project-name-field
}

run_shellcheck() {
    shellcheck --version | head -2
    shellcheck -f gcc healthchecks/checks/*.sh healthchecks/*.sh .aidev/*.sh .aidev/runtime/*.sh
}

# Environments the template is rendered under: name, then VAR=value words (no spaces
# inside a value). `postgres-public` also mounts the layer4 snippet.
CADDY_VARIANTS=(
    "defaults CADDY_SITES=api.example.test"
    "public-tls CADDY_SITES=api.example.test,www.example.test CADDY_TLS_SELF_SIGNED=false CADDY_ADMIN_LOCAL_ONLY=true CADDY_ADMIN_ALLOWED_IPS=192.168.1.0/24 DOCKER_GATEWAY_IP6=fd00::1 CADDY_PROXY_PROTOCOL_ALLOW=10.0.0.0/8 CADDY_TRUSTED_PROXIES=private_ranges"
    "no-limits CADDY_SITES=api.example.test CADDY_RATE_LIMIT_ENABLED=false CADDY_ADMIN_LOCAL_ONLY=false CADDY_TRUSTED_PROXIES="
    "legacy-snippet-vars CADDY_SITES=api.example.test TLS_SELF_SIGNED_SNIPPET=caddy/self-signed.snippet LOCAL_ADMIN_ONLY_SNIPPET=caddy/local-admin-only.snippet"
    "postgres-public CADDY_SITES=api.example.test"
)

caddy_validate() {
    local vcases="$out/caddy-validate.tsv" variant name vars dir t0 rc log failed=0
    : > "$vcases"
    for variant in "${CADDY_VARIANTS[@]}"; do
        read -r name vars <<< "$variant"
        dir="$out/caddy-validate/$name"; log="$out/caddy-validate-$name.log"; t0=$SECONDS; rc=0
        local -a envs=(JSONRPC_API_SERVER_NAME=drone ADMIN_ENDPOINT_PROTOCOL=https
            "XDG_DATA_HOME=$PWD/$out/caddy-xdg" "XDG_CONFIG_HOME=$PWD/$out/caddy-xdg")
        # comma-separated CADDY_SITES stand for "a, b" (one word per variant field)
        local v; for v in $vars; do envs+=("${v//,/, }"); done
        {
            echo "env: ${envs[*]}"
            env "${envs[@]}" .aidev/caddy-render.sh "$dir" "$([ "$name" = postgres-public ] && echo postgres-public)" \
                && (cd "$dir" && env "${envs[@]}" caddy validate --config Caddyfile --adapter caddyfile)
        } > "$log" 2>&1 < /dev/null || rc=$?
        [ "$rc" -eq 0 ] || { failed=1; echo "variant $name failed:"; tail -20 "$log"; }
        record "$vcases" "$name" "$rc" "$((SECONDS - t0))" "$log"
    done
    python3 .aidev/junit_cases.py "$out/caddy-validate.xml" caddy-validate "$vcases"
    return "$failed"
}

for s in "$@"; do
    case "$s" in
        compose-lint) step compose-lint compose_lint ;;
        shellcheck) step shellcheck run_shellcheck ;;
        log-rotation) step log-rotation python3 log_rotation/sync_log_rotation.py --check ;;
        caddy-validate) step caddy-validate caddy_validate ;;
        caddy-smoke) step caddy-smoke python3 .aidev/caddy_smoke.py "$out" ;;
        *) echo "unknown step: $s" >&2; exit 2 ;;
    esac
done
python3 .aidev/junit_cases.py "$out/junit.xml" "$suite" "$cases"
exit "$status"
