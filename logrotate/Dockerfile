FROM alpine:latest

RUN apk add --no-cache dcron logrotate
# change logrotate to run hourly, instead of the default daily
# that just sets the minimum interval, you can still rotate 
# daily/weekly/etc via config
RUN mv /etc/periodic/daily/logrotate /etc/periodic/hourly

ENTRYPOINT ["/usr/sbin/crond", "-f"]
