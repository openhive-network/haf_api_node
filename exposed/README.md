This "exposed" configuration includes directives that allow you to directly access 
the services from other machines -- without this config, the only exposed ports
go to the main webserver, and the only way to access, e.g., hafah's postgrest
server is by sending it through caddy -> jussi -> haproxy -> hafah-postgrest

Exposing ports like this is useful if you want to split the stack across multiple 
machines (e.g., caddy + jussi + redis + varnish on one machine, everything else
on the others).  Or, if you have two redundant servers, and you want to be able
to add backup entries in haproxy that send traffic to the other server.

To use this config, add a line to your .env file telling docker to merge this 
file in:

```
  COMPOSE_FILE=compose.yml:exposed/compose.exposed.yml
```

If this system is not already behind a firewall, you may want to restrict access 
to these  ports, since direct access lets you skip around some of the protections 
such as rate-limiting.  By default, these ports will be open to everybody.
You can restrict them by binding the exposed ports to a specific IP address 
that you trust.  To do this, put this in your .env file:
```
  HAF_API_NODE_EXPOSED_IPADDR=10.10.10.15
```
Alterntively, just run a firewall on this system that restricts access.

Port number assignments are roughly based on what we use in haproxy's config:
The haproxy frontend for hived is on port 7001.  With these config files, we'll
expose the haproxy frontend for hived at 7001, the hived port itself at 17001 (frontend port + 10000)
and the corresponding haproxy healthcheck for hived at 27001 (frontend port + 20000)

### Note
There was a bug in docker tracked here: https://github.com/docker/compose/issues/11404 
which will cause docker to generate an error when you include the compose.exposed.yml
file as described above.  This bug has been fixed in the docker compose repo, and
that fix was recently published in the APT repositories we recommend using in the
top-level README, in the package versioned 2.24.7-1.  If you get errors using these
compose files, make sure your docker compose package is up to date.
