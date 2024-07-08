This _log_rotation_ configuration includes directives that cause docker to
limit how much data is kept when logging the container's stdout/stderr.

In the default configuration, without these files, docker will log using the
system's default logging configuration.  By default, this uses the json-file
logging driver, which writes all output to a text file in _JSON Lines_ format.
By default, logs will be kept forever.  This puts you at risk of running out
of disk space eventually, though if you have large disks, low API traffic,
or you regularly restart your containers, this may never be an issue for you.

Including this config:
 - switches the logging driver to the more efficient _local_, and
 - sets finite limits on how much space the log files can take

At the moment, these limits are high, but should allow a public API node to
keep at least one day's worth of logs for the most verbose containers.

To use this config, add a line to your .env file telling docker to merge this 
file in:

```
  COMPOSE_FILE=compose.yml:log_rotation/compose.log_rotation.yml
```
