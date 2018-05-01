ARG ubuntu_version=16.04
FROM ubuntu:$ubuntu_version
# needed to do again after FROM due to docker limitation
ARG ubuntu_version

ARG DEBIAN_FRONTEND=noninteractive
# do not start services during installation as this will fail and log a warning / error.
RUN echo "#!/bin/sh\nexit 0" > /usr/sbin/policy-rc.d

# basic dependencies
RUN apt-get update
RUN apt-get install -y wget git build-essential software-properties-common pkg-config locales
RUN apt-get install -y libicu-dev libblocksruntime0
RUN apt-get install -y lsof dnsutils netcat-openbsd # used by integration tests

# local
RUN locale-gen en_US.UTF-8
RUN locale-gen en_US en_US.UTF-8
RUN dpkg-reconfigure locales
RUN echo 'export LANG=en_US.UTF-8' >> $HOME/.profile
RUN echo 'export LANGUAGE=en_US:en' >> $HOME/.profile
RUN echo 'export LC_ALL=en_US.UTF-8' >> $HOME/.profile

# known_hosts
RUN mkdir -p $HOME/.ssh
RUN touch $HOME/.ssh/known_hosts
RUN ssh-keyscan github.com 2> /dev/null >> $HOME/.ssh/known_hosts

# clang
RUN apt-get install -y clang-3.9
RUN update-alternatives --install /usr/bin/clang clang /usr/bin/clang-3.9 100
RUN update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-3.9 100

# modern curl, if needed
ARG install_curl_from_source
RUN [ ! -z $install_curl_from_source ] || apt-get install -y curl libcurl3 libz-dev
RUN [ -z $install_curl_from_source ] || apt-get install -y libssl-dev
RUN [ -z $install_curl_from_source ] || mkdir $HOME/.curl
RUN [ -z $install_curl_from_source ] || wget -q https://curl.haxx.se/download/curl-7.50.3.tar.gz -O $HOME/curl.tar.gz
RUN [ -z $install_curl_from_source ] || tar xzf $HOME/curl.tar.gz --directory $HOME/.curl --strip-components=1
RUN [ -z $install_curl_from_source ] || ( cd $HOME/.curl && ./configure --with-ssl && make && make install && cd - )
RUN [ -z $install_curl_from_source ] || ldconfig

# ruby and jazzy for docs generation
RUN apt-add-repository -y ppa:brightbox/ruby-ng
RUN apt-get update
RUN apt-get install -y ruby2.4 ruby2.4-dev libsqlite3-dev
RUN gem install jazzy --no-ri --no-rdoc

# swift
ARG swift_version=4.0.3
RUN mkdir $HOME/.swift
RUN wget -q https://swift.org/builds/swift-${swift_version}-release/ubuntu$(echo $ubuntu_version | sed 's/\.//g')/swift-${swift_version}-RELEASE/swift-${swift_version}-RELEASE-ubuntu${ubuntu_version}.tar.gz -O $HOME/swift.tar.gz
RUN tar xzf $HOME/swift.tar.gz --directory $HOME/.swift --strip-components=1
RUN echo 'export PATH="$HOME/.swift/usr/bin:$PATH"' >> $HOME/.profile
RUN echo 'export LINUX_SOURCEKIT_LIB_PATH="$HOME/.swift/usr/lib"' >> $HOME/.profile

# script to allow mapping framepointers on linux
RUN mkdir -p $HOME/.scripts
RUN wget -q https://raw.githubusercontent.com/apple/swift/master/utils/symbolicate-linux-fatal -O $HOME/.scripts/symbolicate-linux-fatal
RUN chmod 755 $HOME/.scripts/symbolicate-linux-fatal
RUN echo 'export PATH="$HOME/.scripts:$PATH"' >> $HOME/.profile
