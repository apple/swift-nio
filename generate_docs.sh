#!/bin/bash

set -e

my_path="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

swift_version=${swift_version:-4.0.2}
version=$(git describe --abbrev=0 --tags)
modules=(SwiftNIO NIOHTTP1 NIOTLS NIOOpenSSL)

if [[ $CI == true ]]; then
  # CI setup, assume this is running in an ubuntu docker container:
  # to test locally:
  # docker run -v `pwd`:/code -w /code -e CI=true ubuntu:14.04 /bin/bash /code/generate_docs.sh

  # setup ruby
  gpg --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 409B6B1796C275462A1703113804BB82D39DC0E3 7D2BAF1CF37B13E2069D6956105BD0E739499BDB
  \curl -sSL https://get.rvm.io | bash -s stable
  source $HOME/.rvm/scripts/rvm
  rvm requirements
  rvm install 2.4
  # setup jazzy
  gem install jazzy --no-ri --no-rdoc

  # setup swift
  rm -rf "$HOME/.swiftenv"
  git clone https://github.com/kylef/swiftenv.git "$HOME/.swiftenv"
  export SWIFTENV_ROOT="$HOME/.swiftenv"
  export PATH="$SWIFTENV_ROOT/bin:$HOME/scripts:$PATH"
  eval "$(swiftenv init -)"
  swiftenv install $swift_version
  # set path swift libs
  export LINUX_SOURCEKIT_LIB_PATH="$SWIFTENV_ROOT/versions/$swift_version/usr/lib"

  # setup source-kitten
  source_kitten_source_path=~/.SourceKitten
  source_kitten_path="$source_kitten_source_path/.build/x86_64-unknown-linux/debug"
  git clone https://github.com/jpsim/SourceKitten.git "$source_kitten_source_path"
  rm -rf "$source_kitten_source_path/.swift-version"
  cd "$source_kitten_source_path" && swift build && cd "$my_path"

  # build swift-nio if required
  if [[ ! -d "$my_path/.build/x86_64-unknown-linux" ]]; then
    swift build
  fi

  # generate
  for module in "${modules[@]}"; do
    if [[ ! -f "$my_path/$module.json" ]]; then
      "$source_kitten_path/sourcekitten" doc --spm-module $module > "$my_path/$module.json"
    fi
  done
elif [[ "$(uname -s)" != Darwin ]]; then
    echo >&2 "Sorry, at this point in time documentation can only be generated on macOS."
    exit 1
fi

if ! command -v jazzy > /dev/null; then
    echo >&2 "ERROR: jazzy not installed, install with"
    echo >&2
    echo >&2 "  gem install jazzy"
    exit 1
fi

cd "$my_path"

[[ -d docs/$version ]] || mkdir -p docs/$version
[[ -d swift-nio.xcodeproj ]] || swift package generate-xcodeproj

# run jazzy
jazzy_args=(--clean
            --readme docs/$version/README.md
            --author 'SwiftNIO Team'
            --author_url https://github.com/apple/nio
            --github_url https://github.com/apple/nio
            --xcodebuild-arguments -scheme,swift-nio-Package)

for module in "${modules[@]}"; do
  args=("${jazzy_args[@]}"  --output "docs/$version/$module" --module "$module")
  if [[ -f $module.json ]]; then
    args+=(--sourcekitten-sourcefile $module.json)
  fi
  jazzy "${args[@]}"
done

# create index
cat >> "docs/$version/index.html" <<EOF
<b>SwiftNIO Docs</b>
<br>
<ul>SwiftNIO contains multiple modules:
EOF
for module in "${modules[@]}"; do
  echo "<li><a href="$module/index.html">$module</a>" >> "docs/$version/index.html"
done

# push to github pages
if [[ $CI == true ]]; then
  BRANCH_NAME=$(git rev-parse --abbrev-ref HEAD)
  GIT_AUTHOR=$(git --no-pager show -s --format='%an <%ae>' HEAD)
  git fetch origin +gh-pages:gh-pages
  git checkout gh-pages
  rm -rf docs/current
  cp -r docs/$version docs/current
  git add docs
  echo '<html><head><meta http-equiv="refresh" content="0; url=docs/current" /></head></html>' > index.html
  git add index.html
  git commit --author="$GIT_AUTHOR" -m "publish $version docs"
  git push origin gh-pages
  git checkout -f $BRANCH_NAME
fi
