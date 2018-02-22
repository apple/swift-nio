#!/bin/bash

set -e

my_path="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
root_path="$my_path/.."
swift_version=${swift_version:-4.0.2}
version=$(git describe --abbrev=0 --tags || echo "0.0.0")
modules=(NIO NIOHTTP1 NIOTLS NIOFoundationCompat)

if [[ "$(uname -s)" == "Linux" ]]; then
  # setup ruby
  if ! command -v ruby > /dev/null; then
    gpg --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 409B6B1796C275462A1703113804BB82D39DC0E3 7D2BAF1CF37B13E2069D6956105BD0E739499BDB
    \curl -sSL https://get.rvm.io | bash -s stable
    source $HOME/.rvm/scripts/rvm
    rvm requirements
    rvm install 2.4
  fi

  # setup swift
  if ! command -v swift > /dev/null; then
    rm -rf "$HOME/.swiftenv"
    git clone https://github.com/kylef/swiftenv.git "$HOME/.swiftenv"
    export SWIFTENV_ROOT="$HOME/.swiftenv"
    export PATH="$SWIFTENV_ROOT/bin:$HOME/scripts:$PATH"
    eval "$(swiftenv init -)"
    swiftenv install $swift_version
    # set path swift libs
    export LINUX_SOURCEKIT_LIB_PATH="$SWIFTENV_ROOT/versions/$swift_version/usr/lib"
  fi

  # build code if required
  if [[ ! -d "$root_path/.build/x86_64-unknown-linux" ]]; then
    swift build
  fi
  # setup source-kitten if required
  source_kitten_source_path="$root_path/.SourceKitten"
  if [[ ! -d "$source_kitten_source_path" ]]; then
    git clone https://github.com/jpsim/SourceKitten.git "$source_kitten_source_path"
  fi
  source_kitten_path="$source_kitten_source_path/.build/x86_64-unknown-linux/debug"
  if [[ ! -d "$source_kitten_path" ]]; then
    rm -rf "$source_kitten_source_path/.swift-version"
    cd "$source_kitten_source_path" && swift build && cd "$root_path"
  fi
  # generate
  mkdir -p "$root_path/.build/sourcekitten"
  for module in "${modules[@]}"; do
    if [[ ! -f "$root_path/.build/sourcekitten/$module.json" ]]; then
      "$source_kitten_path/sourcekitten" doc --spm-module $module > "$root_path/.build/sourcekitten/$module.json"
    fi
  done
fi

[[ -d docs/$version ]] || mkdir -p docs/$version
[[ -d swift-nio.xcodeproj ]] || swift package generate-xcodeproj

# run jazzy
if ! command -v jazzy > /dev/null; then
  gem install jazzy --no-ri --no-rdoc
fi
module_switcher="docs/$version/README.md"
jazzy_args=(--clean
            --author 'SwiftNIO Team'
            --readme "$module_switcher"
            --author_url https://github.com/apple/swift-nio
            --github_url https://github.com/apple/swift-nio
            --theme fullwidth
            --xcodebuild-arguments -scheme,swift-nio-Package)
cat > "$module_switcher" <<EOF
# SwiftNIO Docs

SwiftNIO contains multiple modules:

EOF

for module in "${modules[@]}"; do
  echo " - [$module](../$module/index.html)" >> "$module_switcher"
done

for module in "${modules[@]}"; do
  args=("${jazzy_args[@]}"  --output "$root_path/docs/$version/$module" --module "$module")
  if [[ -f "$root_path/.build/sourcekitten/$module.json" ]]; then
    args+=(--sourcekitten-sourcefile "$root_path/.build/sourcekitten/$module.json")
  fi
  jazzy "${args[@]}"
done

# push to github pages
if [[ $CI == true ]]; then
  BRANCH_NAME=$(git rev-parse --abbrev-ref HEAD)
  GIT_AUTHOR=$(git --no-pager show -s --format='%an <%ae>' HEAD)
  git fetch origin +gh-pages:gh-pages
  git checkout gh-pages
  rm -rf docs/current
  cp -r docs/$version docs/current
  git add --all docs
  echo '<html><head><meta http-equiv="refresh" content="0; url=docs/current/NIO/index.html" /></head></html>' > index.html
  git add index.html
  changes=$(git diff-index --name-only HEAD)
  if [[ -n "$changes" ]]; then
    git commit --author="$GIT_AUTHOR" -m "publish $version docs"
    git push origin gh-pages
  else
    echo "no changes detected"
  fi
  git checkout -f $BRANCH_NAME
fi
