# ``_NIOFileSystem``

A file system library for Swift.

## Overview

This module implements a file system library for Swift, providing ways to interact with and manage
files. It provides a concrete ``FileSystem`` for interacting with the local file system in addition
to a set of protocols for creating other file system implementations.

``_NIOFileSystem`` is cross-platform with the following caveats:
- _Platforms don't have feature parity or system-level API parity._ Where this is the case these
  implementation details are documented. One example is copying files, on Apple platforms files are
  cloned if possible.
- _Features may be disabled on some systems._ One example is extended attributes.
- _Some types have platform specific representations._ These include the following:
  - File paths on Apple platforms and Linux (e.g. `"/Users/hal9000/"`) are different to paths on
    Windows (`"C:\Users\hal9000"`).
  - Information about files is different on different platforms. See ``FileInfo`` for further
    details.

## A Brief Tour

The following sample code demonstrates a number of the APIs offered by this module:

@Snippet(path: "swift-nio/Snippets/NIOFileSystemTour")

In depth documentation can be found in the following sections.

## Topics

### Interacting with the Local File System

- ``FileSystem``
- ``FileHandle``
- ``ReadFileHandle``
- ``WriteFileHandle``
- ``ReadWriteFileHandle``
- ``DirectoryFileHandle``
- ``withFileSystem(numberOfThreads:_:)``

### File and Directory Information

- ``FileInfo``
- ``FileType``

### Reading Files

- ``FileChunks``
- ``BufferedReader``

### Writing Files

- ``BufferedWriter``

### Listing Directories

- ``DirectoryEntry``
- ``DirectoryEntries``

### Errors

``FileSystemError`` is the only top-level error type thrown by the package (apart from Swift's
`CancellationError`).

- ``FileSystemError``
- ``FileSystemError/SystemCallError``

### Creating a File System

Custom file system's can be created by implementing ``FileSystemProtocol`` which depends on a number
of other protocols. These include the following:

- ``FileSystemProtocol``
- ``FileHandleProtocol``
- ``ReadableFileHandleProtocol``
- ``WritableFileHandleProtocol``
- ``ReadableAndWritableFileHandleProtocol``
- ``DirectoryFileHandleProtocol``
