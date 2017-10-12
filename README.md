

@linux
======

**creating a docker image for linux**

```
# create the docker image for linux (one time or when dockerfile changes)
$ docker build . --build-arg version=4.0 -t=nio
```

**using the linux docker image**

```
# use the docker image, bind mount the current dir with code
$ docker run -it -v `pwd`:/code -w /code swift-nio bash
```

```
# do your thing
$ swift build
$ swift test
```

**testing on linux**

to know which tests to run on linux, swift requires a special mapping file called `LinuxMain.swift` and explicit mapping of each test case into a static list of tests. this is a real pita, but we are here to help!

```
# generate linux tests
$ ruby generate_linux_tests.rb
```
