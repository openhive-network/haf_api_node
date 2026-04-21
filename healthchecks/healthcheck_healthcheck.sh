#! /bin/sh
exec netstat -tln | grep -E ':(7001|7002|7003|7004|7005|7009|7011|7013|7014|7015)\b' | wc -l | grep -q '^10$'
