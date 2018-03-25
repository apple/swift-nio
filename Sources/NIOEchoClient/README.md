# NIOEchoClient

This sample application provides a simple echo client that will send a single line to an echo server and wait for a response. Invoke it using one of the following syntaxes:

```bash
swift run NIOEchoClient  # Connects to a server on ::1, port 9999.
swift run NIOEchoClient 9899  # Connects to a server on ::1, port 9899
swift run NIOEchoClient /path/to/unix/socket  # Connects to a server using the given UNIX socket
swift run NIOEchoClient echo.example.com 9899  # Connects to a server on echo.example.com:9899
```

