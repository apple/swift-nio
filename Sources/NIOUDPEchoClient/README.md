# NIOUDPEchoClient

This sample application provides a simple UDP echo client that will send a single line to a UDP echo server and wait for a response. Invoke it using one of the following syntaxes:

```bash
swift run NIOUDPEchoClient # Connects to a server on ::1, server UDP port 9999 and listening port 8888.
swift run NIOUDPEchoClient 9899 9888 # Connects to a server on ::1, server UDP port 9899 and listening port 9888
swift run NIOUDPEchoClient echo.example.com 9899 9888 # Connects to a server on echo.example.com:9899 and listens on UDP port 9888
```

