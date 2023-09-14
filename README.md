# Using docker compose to run the HAF

---

Files used in the process:

- haf_base.yaml *(haf instance)*
- backend.yaml *(backend application: pgadmin, phgero to preview and manage the database)*
- app.yaml *(example of application: postgrest and swagger)*

and environment files:

- .env.dev *(for the developer stage)*
- .env.prod *(for the production stage)*

The environment files specify the versions of images and ports used by applications, as well as the network definition, which varies depending on the version of the environment being run.

This example deployment assumes that haf-datadir local subdirecory can be directly used as HAF instance data directory, by specifying actual path in environment file.
As usually, if you want to perform replay, you have to put a block_log file into `haf-datadir/blockchain` and specify --replay option to the Hived startup options (see ARGUMENTS variable definition in the example env files).

## Launch example

---

1.start/stop naked HAF instance using prod environment

```SH
docker compose --env-file .env.prod -f haf_base.yaml up -d
docker compose --env-file .env.prod -f haf_base.yaml down
```

2.start/stop HAF instance with pgadmin and pghero in dev enviroment

```SH
docker compose --env-file .env.dev -f haf_base.yaml -f backend.yaml up -d
docker compose --env-file .env.dev -f haf_base.yaml -f backend.yaml down
```

3.start/stop HAF instance with pgadmin and pghero and some apps in dev enviroment

```SH
docker compose --env-file .env.dev -f haf_base.yaml -f backend.yaml -f app.yaml up -d
docker compose --env-file .env.dev -f haf_base.yaml -f backend.yaml -f app.yaml down
```
