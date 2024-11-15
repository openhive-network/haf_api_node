This "email-alerts" configuration allows you to have haproxy send you email
messages to notify you whenever a service goes down.

These alerts are very basic, consisting of a single line that looks like:
```
[HAProxy Alert] Server balance-tracker/balance-tracker is DOWN. 0 active and 0 backup servers left. 0 sessions active, 0 requeued, 0 remaining in queue
```

It's not much, but it's enough to tell you that there's something that needs 
your attention.  If you have a more sophisticated monitoring system like
Zabbix or Nagios, you may want to look into using that instead.

To use this config, add a line to your .env file telling docker to merge this 
file in:

```
COMPOSE_FILE=compose.yml:email-alerts/compose.email-alerts.yml
```

In addition, you'll need to set several other settings in your .env file:

First, set the login information for your SMTP server.
```
SMTP_HOST="smtp.gmail.com:587"
SMTP_USER="me@gmail.com"
SMTP_PASS="myapppassword"
# Auth defaults to "plain", you can uncomment to use "login" instead
# SMTP_AUTH_TYPE="login"
```

You also need to tell it where to send the emails.  If you need to, you
can customize the "from" address and alert threshold.
```
HAPROXY_EMAIL_TO="me@gmail.com"
# HAPROXY_EMAIL_FROM="noreply@${PUBLIC_HOSTNAME}"
# HAPROXY_EMAIL_LEVEL="notice"
```
