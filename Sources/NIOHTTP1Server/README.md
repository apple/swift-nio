# NIOHTTP1Server

This sample application provides a HTTP server that supports a number of query methods for testing purposes. Invoke it using one of the following syntaxes:

```bash
swift run NIOHTTP1Server  # Binds the server on ::1, port 8888.
swift run NIOHTTP1Server 8988  # Binds the server on ::1, port 8988
swift run NIOHTTP1Server /path/to/unix/socket  # Binds the server using the given UNIX socket
swift run NIOHTTP1Server 192.168.0.5 8988  # Binds the server on 192.168.0.5:8988
```

The final three syntaxes optionally accept an additional argument, a path to a directory of files to serve from the webserver. The first syntax does not, as that would conflict with the UNIX socket path syntax.

So, for example, to spin up a local webserver on port 80 serving a specific directory, you can run:

```bash
swift run NIOHTTP1Server localhost 80 /var/www
```

## Paths

The server has the following endpoints:

- `/`: serves "Hello world!"
- `/sendfile/*`: serves the file at path `*` to the client, using `sendfile`.
- `/fileio/*`: serves the file at path `*` to the client by reading the file in to memory in chunks.
- `/dynamic/echo`: Echoes the request body back to the client.
- `/dynamic/echo_balloon`: Echoes the request body back to the client after buffering it entirely in memory first.
- `/dynamic/pid`: Echoes pack the PID of the server.
- `/dynamic/write-delay`: Echoes "Hello world" after a 100ms delay.
- `/dynamic/info`: Sends information about the received request.
- `/dynamic/trailers`: Sends the PID along with some HTTP trailers.
- `/dynamic/continuous`: Sends a chunked body forever.
- `/dynamic/count-to-ten`: Sends the numbers 1 through 10 in separate chunks.
- `/dynamic/client-ip`: Sends what the server believes the client IP is.

