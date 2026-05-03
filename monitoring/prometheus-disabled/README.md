Bind-mount source for disabling individual `scrape-*.yml` jobs on stacks
where the target service isn't running.

When Prometheus loads `scrape_config_files` and the target's hostname can't
resolve (or the port isn't open), it emits `up{job="..."} 0` every scrape
interval and writes a scrape-error log line. To silence that for stacks
that intentionally don't run a given target, override the per-job file
with the empty-list placeholder shipped here:

```yaml
# in compose.override.yml — example: hbt4 frontends don't run hived
services:
  prometheus:
    volumes:
      - ./monitoring/prometheus-disabled/empty-scrape.yml:/etc/prometheus/scrape-hived-pme.yml:ro
      - ./monitoring/prometheus-disabled/empty-scrape.yml:/etc/prometheus/scrape-postgresexporter.yml:ro
```

The placeholder is a valid (empty) scrape_config_files entry, so Prometheus
loads it without error and registers no jobs from it.
