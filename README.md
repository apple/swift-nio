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

## Prerequisites for Linux (using Docker)

### Creating a Docker Image for Linux

```
# create the docker image for linux (one time or when Dockerfile changes)
$ docker build . --build-arg version=4.0 -t=nio
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

    brew install openssl
