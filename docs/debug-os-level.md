# Debugging NIO programs from the OS level


## List all file descriptors

```
lsof -p $(pgrep NIOEchoServer)
```

## Dump traffic to file

For example to dump everything on port `12345` on interface `en0`:

```
sudo tcpdump -i en0 -w /tmp/dump.pcap '' 'port 12345'
```

## List event file descriptors

### macOS

```
lskq -p $(pgrep NIOEchoServer)
```

### Linux

```
pid=$(pgrep NIOEchoServer); for fd_file in /proc/$pid/fd/*; do if [[ "$(readlink "$fd_file")" =~ eventpoll ]]; then fd=$(basename "$fd_file"); echo "Epoll $fd"; echo =====; cat "/proc/$pid/fdinfo/$fd"; fi; done
```


## Info about UNIX Domain Socket connections

### Linux

```
sudo netstat --protocol=unix -peona
```

### macOS

```
netstat -n -a -f unix
```

## Info about TCP connections

### Linux

```
sudo netstat --tcp -peona
```

### macOS

```
netstat -n -p tcp -a
```

## Info about TCP connections


### Linux

```
sudo netstat --udp -peona
```

### macOS

```
netstat -n -p udp -a
```
