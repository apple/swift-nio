# NIOUDPEchoServer

This sample application provides a simple UDP echo server that sends clients back whatever data they send it. Invoke it using one of the following syntaxes:

```bash
swift run NIOUDPEchoServer  # Binds the server on ::1, port 9999.
swift run NIOUDPEchoServer 9899  # Binds the server on ::1, port 9899
swift run NIOUDPEchoServer /path/to/unix/socket  # Binds the server using the given UNIX socket
swift run NIOUDPEchoServer 192.168.0.5 9899  # Binds the server on 192.168.0.5:9899
```

