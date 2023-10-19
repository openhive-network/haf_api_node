Place Caddyfile snippets here.  All files with extension ".snippet", will be 
automatically included in the webserver config.  There are two things you
will likely want to do by adding snippets:

## Configure TLS
By default, this config will use a self-signed SSL certificate.  To disable
the self-signed certificate, change the `TLS_SELF_SIGNED_SNIPPET` variable
in your `.env` file.  By default, it will attempt to get a certificate using
the ACME HTTP-01 challenge.

If you need to use a different challenge type like DNS challenges, or use
static certificates, put the necessary statements in a `.snippet` file.

For example:
```
# use LetsEncrypt's staging server
tls my@email.address {
    ca https://acme-staging-v02.api.letsencrypt.org/directory
}
```

## Restrict access to the admin endpoints

You can restrict access to the admin pages and helper apps by adding 
snippets in this directory.  For example, to restrict access only to
the localhost, create a file named, say, `local_admin_only.snippet`
in this directory, with the contents:
```
handle /admin/* {
  @admin_prohibited not remote_ip 127.0.0.1
  respond @admin_prohibited "Access denied" 403
}
```
(or restrict to the local network with `192.168.1.0/24`, etc)

or to require a password:
```
# require the user to login with user: "haf_admin", password: "password"
# to access all /admin urls.  The username can be anything you like,
# and obviously, change the password to something secure before exposing
# this server to the world at large.
# Generate a new password hash with:
#   docker run --rm -it caddy:2.7.4-alpine caddy hash-password
basicauth /admin/* {
  haf_admin $2a$14$Wfk1vAajVfY52N7TL4nD3.Fls9PBL5NSjaZ.l4A8P1Az6XBemhTr2
}
```
