FROM ubuntu:14.04
MAINTAINER tomerd@apple.com

# local
RUN locale-gen en_US en_US.UTF-8
RUN dpkg-reconfigure locales
RUN echo 'export LANG=en_US.UTF-8' >> $HOME/.profile
RUN echo 'export LANGUAGE=en_US:en' >> $HOME/.profile
RUN echo 'export LC_ALL=en_US.UTF-8' >> $HOME/.profile

# basic dependencies
RUN apt-get update
RUN apt-get install -y wget git software-properties-common pkg-config
RUN apt-get install -y libicu-dev libblocksruntime0
RUN apt-get install -y lsof dnsutils # used by integration tests

# clang
RUN wget -O - https://apt.llvm.org/llvm-snapshot.gpg.key | apt-key add -
RUN apt-add-repository "deb http://apt.llvm.org/trusty/ llvm-toolchain-trusty-5.0 main"
RUN apt-get update
RUN apt-get install -y clang-5.0 lldb-5.0
RUN update-alternatives --install /usr/bin/clang clang /usr/bin/clang-5.0 100
RUN update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-5.0 100

# modern curl
#RUN apt-get install -y curl
RUN apt-get install -y build-essential libssl-dev
RUN mkdir $HOME/.curl
RUN wget -q http://curl.haxx.se/download/curl-7.50.3.tar.gz -O $HOME/curl.tar.gz
RUN tar xzf $HOME/curl.tar.gz --directory $HOME/.curl --strip-components=1
RUN cd $HOME/.curl && ./configure --with-ssl && make && make install && cd -
RUN ldconfig

# swift
ARG version=4.0.2
RUN mkdir $HOME/.swift
RUN wget -q https://swift.org/builds/swift-${version}-release/ubuntu1404/swift-${version}-RELEASE/swift-${version}-RELEASE-ubuntu14.04.tar.gz -O $HOME/swift.tar.gz
RUN tar xzf $HOME/swift.tar.gz --directory $HOME/.swift --strip-components=1
RUN echo 'export PATH="$HOME/.swift/usr/bin:$PATH"' >> $HOME/.profile
RUN echo 'export LINUX_SOURCEKIT_LIB_PATH="$HOME/.swift/usr/lib"' >> $HOME/.profile

# script to allow mapping framepointers on linux
RUN mkdir -p $HOME/.scripts
RUN wget -q https://raw.githubusercontent.com/apple/swift/master/utils/symbolicate-linux-fatal -O $HOME/.scripts/symbolicate-linux-fatal
RUN chmod 755 $HOME/.scripts/symbolicate-linux-fatal
RUN echo 'export PATH="$HOME/.scripts:$PATH"' >> $HOME/.profile

# ruby
RUN apt-add-repository -y ppa:brightbox/ruby-ng
RUN apt-get update
RUN apt-get install -y ruby2.4 ruby2.4-dev libsqlite3-dev

# known_hosts
RUN mkdir -p $HOME/.ssh
RUN touch $HOME/.ssh/known_hosts
RUN ssh-keyscan github.com >> $HOME/.ssh/known_hosts
