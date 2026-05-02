Place Caddyfile snippets here that should be imported *inside* the
admin handler, after `/admin` has been stripped from the URI.

Files with extension `.snippet` in this directory are imported by
`Caddyfile.tmpl` from two locations:

  - inside `handle @admin_grafana { ... }`
  - inside `handle @admin { ... }` (after `uri strip_prefix /admin`)

That means snippets here see paths *without* the leading `/admin` —
write rules like `handle_path /foo/*`, not `handle_path /admin/foo/*`.

Use this directory (rather than the sibling `snippets/`) for routes
that should only be reachable under `/admin/*`. Snippets in
`snippets/` are imported at site level and apply to every request.

## Example: route /admin/primary/haproxy and /admin/secondary/haproxy
to two different HAProxy instances on a multi-server deployment.
Save as `dual-stack-paths.snippet`:

```
redir /primary/haproxy /admin/primary/haproxy/
handle_path /primary/haproxy/* {
  rewrite * /admin/primary/haproxy{uri}
  reverse_proxy http://172.16.100.4:27200
}

redir /secondary/haproxy /admin/secondary/haproxy/
handle_path /secondary/haproxy/* {
  rewrite * /admin/secondary/haproxy{uri}
  reverse_proxy http://172.16.100.5:27200
}
```

The matching upstream HAProxy instances must serve their stats page
at the same URI Caddy forwards (e.g., set
`stats uri /admin/primary/haproxy/` on the primary host's HAProxy).
