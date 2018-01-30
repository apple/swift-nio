# SwiftNIO (Non-blocking IO in Swift)

SwiftNIO is an asynchronous event-driven network application framework
for rapid development of maintainable high performance protocol servers & clients.

It's like [Netty](https://netty.io) but in Swift.

## Documentation

 - [API documentation](https://apple.github.io/swift-nio/docs/current/NIO/index.html)


## Compile, Test and Run

For both Linux and macOS

    ./swiftw build
    ./swiftw test
    ./swiftw run NIOEchoServer

and from some other terminal

    echo Hello SwiftNIO | nc localhost 9999

## Alternative way using `docker-compose`

First `cd docker` and then:

- `docker-compose test`

  Will create a base image with Swift 4.0 (if missing), compile SwiftNIO and run tests

- `docker-compose up echo`

  Will create a base image, compile SwiftNIO, and run a sample `NIOEchoServer` on
  `localhost:9999`. Test it by `echo Hello SwiftNIO | nc localhost 9999`.

- `docker-compose up http`

  Will create a base image, compile SwiftNIO, and run a sample `NIOHTTP1Server` on
  `localhost:8888`. Test it by `curl http://localhost:8888`

- `docker-compose run swift-nio /scripts/gen-cert.sh`

  Will generate self-signed certificate for a TLS Server example.

- `docker-compose up tls`

  Will create a base image, compile SwiftNIO, and run a sample `NIOTLSServer`
  on `localhost:4433`. It is an echo server that you can test using
  `openssl s_client -crlf -connect localhost:4433`.


## Prerequisites for Linux (using Docker)

### Creating a Docker Image for Linux

```
# create the docker image for linux (one time or when Dockerfile changes)
$ docker build . -f docker/Dockerfile --build-arg version=4.0 -t=nio
```

### Using the Linux Docker Image

```
# use the docker image, bind mount the current dir with code
$ docker run -it -v `pwd`:/code -w /code swift-nio bash
```

```
# do your thing
$ ./swiftw build
$ ./swiftw test
```

### Testing on Linux

to know which tests to run on linux, swift requires a special mapping file called `LinuxMain.swift` and explicit mapping of each test case into a static list of tests. this is a real pita, but we are here to help!

```
# generate linux tests
$ ruby generate_linux_tests.rb
```

