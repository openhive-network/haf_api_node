FROM alpine:latest

RUN apk add --no-cache dcron logrotate run-parts
# change logrotate to run hourly, instead of the default daily
# that just sets the minimum interval, you can still rotate 
# daily/weekly/etc via config
RUN mv /etc/periodic/daily/logrotate /etc/periodic/hourly

ENTRYPOINT ["/bin/sh", "-c", "install -o root -g root -m 644 /etc/logrotate.d.sources/* /etc/logrotate.d && exec /usr/sbin/crond -c /etc/crontabs -f"]
