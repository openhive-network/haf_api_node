Deployment-local Prometheus scrape config extension point.

Files placed here are picked up by Prometheus via the `scrape_config_files:
- "extra/*.yml"` glob in `../prometheus/prometheus.yml`. The container mounts
this directory at `/etc/prometheus/extra/` (read-only). To use a different
source dir, set `MONITORING_EXTRA_CONFIG_DIR` in `.env`.

Each file should contain a list of scrape job definitions, exactly like the
sibling `../prometheus/scrape-*.yml` files. Example federation job for a
central Prometheus that pulls from leaf instances on other hosts:

```yaml
# scrape-federation.yml
scrape_configs:
  - job_name: "federate-primary-backend"
    honor_labels: true
    metrics_path: /federate
    params:
      'match[]':
        - '{job!=""}'
    static_configs:
      - targets: ["172.16.100.5:29090"]

  - job_name: "federate-secondary-backend"
    honor_labels: true
    metrics_path: /federate
    params:
      'match[]':
        - '{job!=""}'
    static_configs:
      - targets: ["172.16.100.5:49090"]
```

`honor_labels: true` preserves the `role`/`instance` external_labels set on
the leaf instance, so federated metrics keep their origin identity in
Grafana. Set those labels per-host via `PROMETHEUS_ROLE` and
`PROMETHEUS_INSTANCE` env vars (see `.env.example`).
