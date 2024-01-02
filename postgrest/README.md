The default PostgREST image is just a static binary, it doesn't contain a
full Linux environment.  In order to support docker compose healthchecks,
we need to be able to exec a `wget` or `curl` command inside the container,
so we need to build our own custom docker image that contains the original
postgrest static binary plus wget.

See also: https://github.com/PostgREST/postgrest/tree/main/nix/tools/docker
