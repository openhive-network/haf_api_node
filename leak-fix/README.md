On high-volume API servers, certain request patterns have triggered a slow 
memory leak in drone.  The leak appears to be related to actix-http's BytesMut
buffers not getting garbage collected when traffic either exceeds a certain
volume or a certain access pattern exists.  The exact mechanism isn't
understood.

Limiting each connection to 100 requests completely eliminates this problem.
This workaround adds an nginx service in front of drone that's configured to close
its connection every 100 requests. 
So far, all attempts to implement this workaround inside drone have failed.

To use this config, add a line to your .env file telling docker to merge this 
file in:

```
  COMPOSE_FILE=compose.yml:leak-fix/compose.leak-fix.yml
```

