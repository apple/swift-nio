# ``NIOFileSystem``

A file system library for Swift.

## Overview

This module implements a file system library for Swift, providing ways to interact with and manage
files. It provides a concrete ``FileSystem`` for interacting with the local file system in addition
to a set of protocols for creating other file system implementations.

``NIOFileSystem`` is cross-platform with the following caveats:
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

```swift
import NIOFileSystem

// NIOFileSystem provides access to the local file system via the FileSystem
// type which is available as a global shared instance.
let fileSystem = FileSystem.shared

// Files can be inspected by using 'info':
if let info = try await fileSystem.info(forFileAt: "/Users/hal9000/demise-of-dave.txt") {
  print("demise-of-dave.txt has type '\(info.type)'")
} else {
  print("demise-of-dave.txt doesn't exist")
}

// Let's find out what's in that file.
do {
  // Reading a whole file requires a limit. If the file is larger than the limit
  // then an error is thrown. This avoids accidentally consuming too much memory
  // if the file is larger than expected.
  let plan = try await ByteBuffer(
    contentsOf: "/Users/hal9000/demise-of-dave.txt",
    maximumSizeAllowed: .mebibytes(1)
  )
  print("Plan for Dave's demise:", String(decoding: plan, as: UTF8.self))
} catch let error as FileSystemError where error.code == .notFound {
  // All errors thrown by the module have type FileSystemError (or
  // Swift.CancellationError). It looks like the file doesn't exist. Let's
  // create it now.
  //
  // The code above for reading the file is shorthand for opening the file in
  // read-only mode and then reading its contents. The FileSystemProtocol
  // has a few different 'withFileHandle' methods for opening a file in different
  // modes. Let's open a file for writing, creating it at the same time.
  try await fileSystem.withFileHandle(
    forWritingAt: "/Users/hal9000/demise-of-dave.txt",
    options: .newFile(replaceExisting: false)
  ) { file in
    let plan = ByteBuffer(string: "TODO...")
    try await file.write(contentsOf: plan.readableBytesView, toAbsoluteOffset: 0)
  }
}

// Directories can be opened like regular files but they cannot be read from or
// written to. However, their contents can be listed:
let path: FilePath? = try await fileSystem.withDirectoryHandle(atPath: "/Users/hal9000/Music") { directory in
  for try await entry in directory.listContents() {
    if entry.name.extension == "mp3", entry.name.stem.contains("daisy") {
      // Found it!
      return entry.path
    }
  }
  // No luck.
  return nil
}

if let path = path {
  print("Found file at '\(path)'")
}

// The file system can also be used to perform the following operations on files
// and directories:
// - copy,
// - remove,
// - rename, and
// - replace.
//
// Here's an example of copying a directory:
try await fileSystem.copyItem(at: "/Users/hal9000/Music", to: "/Volumes/Tardis/Music")

// Symbolic links can also be created (and read with 'destinationOfSymbolicLink(at:)').
try await fileSystem.createSymbolicLink(at: "/Users/hal9000/Backup", withDestination: "/Volumes/Tardis")

// Opening a symbolic link opens its destination so in most cases there's no
// need to read the destination of a symbolic link:
try await fileSystem.withDirectoryHandle(atPath: "/Users/hal9000/Backup") { directory in
  // Beyond listing the contents of a directory, the directory handle provides a
  // number of other functions, many of which are also available on regular file
  // handles.
  //
  // This includes getting information about a file, such as its permissions, last access time,
  // and last modification time:
  let info = try await directory.info()
  print("The directory has permissions '\(info.permissions)'")

  // Where supported, the extended attributes of a file can also be accessed, read, and modified:
  for attribute in try await directory.attributeNames() {
    let value = try await directory.valueForAttribute(attribute)
    print("Extended attribute '\(attribute)' has value '\(value)'")
  }

  // Once this closure returns the file system will close the directory handle freeing
  // any resources required to access it such as file descriptors. Handles can also be opened
  // with the 'openFile' and 'openDirectory' APIs but that places the onus you to close the
  // handle at an appropriate time to avoid leaking resources.
}
```

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
