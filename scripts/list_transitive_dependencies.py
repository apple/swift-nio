#!/usr/bin/env python3
##===----------------------------------------------------------------------===##
##
## This source file is part of the SwiftNIO open source project
##
## Copyright (c) 2022 Apple Inc. and the SwiftNIO project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of SwiftNIO project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##
import json
import sys
import subprocess
import tempfile


def dump_package(path):
    output = subprocess.check_output(["swift", "package", "dump-package"], cwd=path)
    parsed = json.loads(output)
    return parsed


def clone_package(name, url, tag, directory):
    path = directory + "/" + name
    command = ["git", "clone", "--depth", "1", "--branch", tag, url, path]
    subprocess.check_output(command, stderr=subprocess.DEVNULL)
    return path


class TransitiveDependencyResolver(object):
    def __init__(self, temp_dir):
        # Temporary directory to clone dependencies to.
        self._temp_dir = temp_dir
        # Cache of package dumps keyed by name.
        self._packages = {}

        package = dump_package(".")
        self._root_package = package["name"]
        self._packages[self._root_package] = package

    def find_transitive_depenencies(self, module_name):
        # All transitive dependencies. This doubles as the 'visited' modules so
        # we need to remove the target module once we're done.
        dependencies = set()

        # Start from the root package.
        self._find_transitive_dependencies(
            module_name, self._packages[self._root_package], dependencies
        )

        dependencies.remove(module_name)
        return dependencies

    def _find_transitive_dependencies(self, module_name, package, dependencies):
        if module_name in dependencies:
            # Already visited
            return

        dependencies.add(module_name)
        # Visit all dependencies of this module.
        for target in package["targets"]:
            if target["name"] != module_name:
                # Not a target we care about.
                continue

            for dependency in target["dependencies"]:
                if "byName" in dependency:
                    # Target dependency from the package currently being
                    # searched.
                    self._find_transitive_dependencies(
                        dependency["byName"][0], package, dependencies
                    )
                elif "product" in dependency:
                    # Dependency is from another package.
                    dependency_name = dependency["product"][0]
                    package_name = dependency["product"][1]
                    self._ensure_package_is_cached(package, package_name)
                    self._find_transitive_dependencies(
                        dependency_name, self._packages[package_name], dependencies
                    )

    def _ensure_package_is_cached(self, package, package_name):
        if package_name in self._packages:
            return

        # Find the package dependency with the right name.
        for package_dependency in package["dependencies"]:
            dependency = package_dependency["sourceControl"][0]

            is_right_package = (
                dependency["identity"] == package_name
                or dependency.get("nameForTargetDependencyResolutionOnly")
                == package_name
            )

            if not is_right_package:
                continue

            url = dependency["location"]["remote"][0]
            version = dependency["requirement"]["range"][0]["lowerBound"]
            # Path to cloned package.
            path = clone_package(package_name, url, version, self._temp_dir)
            self._packages[package_name] = dump_package(path)
            return


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("USAGE: {} MODULE".format(sys.argv[0]))
        exit(1)

    with tempfile.TemporaryDirectory() as temp_dir:
        resolver = TransitiveDependencyResolver(temp_dir)
        for dependency in resolver.find_transitive_depenencies(sys.argv[1]):
            print(dependency)
