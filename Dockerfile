FROM ubuntu:14.04
MAINTAINER tomerd@apple.com
ENTRYPOINT /bin/bash

# install dependencies
RUN apt-get -y update && apt-get -y install curl git libicu-dev clang-3.8 libpython2.7-dev libxml2 python-lldb-3.9 wget libssl-dev
RUN update-alternatives --install /usr/bin/clang clang /usr/bin/clang-3.8 100
RUN update-alternatives --install /usr/bin/clang++ clang++ /usr/bin/clang++-3.8 100

# install swiftenv
RUN git clone https://github.com/kylef/swiftenv.git ~/.swiftenv
RUN echo 'export SWIFTENV_ROOT="$HOME/.swiftenv"' >> ~/.bashrc
RUN echo 'export PATH="$SWIFTENV_ROOT/bin:$PATH"' >> ~/.bashrc
RUN echo 'export PATH="$HOME/scripts:$PATH"' >> ~/.bashrc
RUN echo 'eval "$(swiftenv init -)"' >> ~/.bashrc

#install script to allow mapping framepointers on linux
RUN mkdir $HOME/scripts
RUN wget -q https://raw.githubusercontent.com/apple/swift/1e078fbdfa768e211e0473cf917511efd73aec86/utils/symbolicate-linux-fatal -O $HOME/scripts/symbolicate-linux-fatal
RUN chmod 755 $HOME/scripts/symbolicate-linux-fatal

# install swift
ARG version
RUN $HOME/.swiftenv/bin/swiftenv install ${version:-3.0.1}
