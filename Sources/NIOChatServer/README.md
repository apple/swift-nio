# NIOChatServer

This sample application provides a chat server that allows multile users to speak to one another. Invoke it using one of the following syntaxes:

```bash
swift run NIOChatServer  # Binds the server on ::1, port 9999.
swift run NIOChatServer 9899  # Binds the server on ::1, port 9899
swift run NIOChatServer /path/to/unix/socket  # Binds the server using the given UNIX socket
swift run NIOChatServer 192.168.0.5 9899  # Binds the server on 192.168.0.5:9899
```

