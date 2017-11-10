# SwiftNIO (Non-blocking IO in Swift)

SwiftNIO is an asynchronous event-driven network application framework
for rapid development of maintainable high performance protocol servers & clients.

It's like [Netty](https://netty.io) but in Swift.



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


## Prerequisites on macOS

### Installation of the Dependencies

    brew install libressl


## TLS

Currently the source tree for SwiftNIO contains bindings for a TLS handler that links against OpenSSL/LibreSSL (more specifically, anything that provides a library called `libssl`).

This binding can cause numerous issues during the build process on different systems, depending on the environment you're in. These will usually manifest as build errors, either during the compilation stage (due to missing development headers) or during the linker stage (due to an inability to find a library to link).

If you encounter any of these errors, here are your options.

### Darwin

On Darwin systems, there is no easily-available copy of `libssl.dylib` with accompanying development headers. For this reason, we recommend installing libressl from Homebrew (`brew install libressl`).

### Linux

On Linux distributions it is almost always possible to get development headers for the system copy of libssl (e.g. via `apt-get install libssl-dev`). If you encounter problems during the compile phase, try running this command.

In some unusual situations you may encounter problems during the link phase. This is usually the result of having an extremely locked down system that does not grant you sufficient permissions to the `libssl.so` on the system.
