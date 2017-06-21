FROM ubuntu:14.04
MAINTAINER tomerd@apple.com
ENTRYPOINT /bin/bash

RUN apt-get -y update

# install dependencies
RUN apt-get -y install curl git libicu-dev clang-3.8 libpython2.7-dev libxml2
RUN update-alternatives --install /usr/bin/clang clang /usr/bin/clang-3.8 100
RUN update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-3.8 100

# install swiftenv
RUN git clone https://github.com/kylef/swiftenv.git ~/.swiftenv
RUN echo 'export SWIFTENV_ROOT="$HOME/.swiftenv"' >> ~/.bashrc
RUN echo 'export PATH="$SWIFTENV_ROOT/bin:$PATH"' >> ~/.bashrc
RUN echo 'eval "$(swiftenv init -)"' >> ~/.bashrc

# install swift
ARG version
RUN $HOME/.swiftenv/bin/swiftenv install ${version:-3.0.1}
