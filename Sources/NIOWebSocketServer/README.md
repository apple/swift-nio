# NIOWebSocketServer

This sample application provides a simple WebSocket server which replies to a limited number of WebSocket message types. Initially, it sends clients back a test page response to a valid HTTP1 GET request. A 405 error will be reported for any other type of request. Once upgraded to WebSocket responses it will respond to a number of WebSocket message opcodes. Invoke it using one of the following syntaxes:

```bash
swift run NIOWebSocketServer  # Binds the server on 'localhost', port 8888.
swift run NIOWebSocketServer 9899  # Binds the server on 'localhost', port 9899
swift run NIOWebSocketServer /path/to/unix/socket  # Binds the server using the given UNIX socket
swift run NIOWebSocketServer 192.168.0.5 9899  # Binds the server on 192.168.0.5:9899
```

## Message Type Opcodes

The WebSocket server responds to the following message type opcodes:

- `connectionClose`: closes the connection.
- `ping`: replies with a 'pong' message containing frame data matching the received message.
- `text`: prints the received string out on the server console.

All other message types are ignored.
