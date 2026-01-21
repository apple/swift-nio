# NIOChatClient

This sample application provides a client for the `NIOChatServer`. Invoke
it using one of the following syntaxes:

```bash
swift run NIOChatClient  # Connects to a server on ::1, port 9999.
swift run NIOChatClient 9899  # Connects to a server on ::1, port 9899
swift run NIOChatClient /path/to/unix/socket  # Connects to a server using the given UNIX socket
swift run NIOChatClient chat.example.com 9899  # Connects to a server on chat.example.com:9899
```

