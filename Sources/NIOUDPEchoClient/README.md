# NIOEchoClient

This sample application provides a simple UDP echo client that will send a single line to a UDP echo server and wait for a response. Invoke it using one of the following syntaxes:

```bash
swift run NIOEchoClient # Connects to a server on ::1, server port 9999 and listening port 8888.
swift run NIOEchoClient 9899 9888 # Connects to a server on ::1, server port 9899 and listening port 9888
swift run NIOEchoClient /path/to/unix/server/socket /path/to/unix/listening/socket # Connects to a server using the first UNIX socket, listening on the second socket.
swift run NIOEchoClient echo.example.com 9899 9888 # Connects to a server on echo.example.com:9899 and listens on port 9888
```

