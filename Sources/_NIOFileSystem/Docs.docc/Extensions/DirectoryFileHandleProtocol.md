# ``_NIOFileSystem/DirectoryFileHandleProtocol``

## Topics

### Iterating a directory

- ``listContents()``

### Opening files with managed lifecycles

Open files and directories at paths relative to the directory handle. These methods manage
the lifecycle of the handles by closing them when the `execute` closure returns.

- ``withFileHandle(forReadingAt:options:execute:)``
- ``withFileHandle(forWritingAt:options:execute:)``
- ``withFileHandle(forReadingAndWritingAt:options:execute:)``
- ``withDirectoryHandle(atPath:options:execute:)``

### Opening files

Open files and directories at paths relative to the directory handle. These methods return
the handle to the caller who is responsible for closing it.

- ``openFile(forReadingAt:options:)``
- ``openFile(forWritingAt:options:)``
- ``openFile(forReadingAndWritingAt:options:)``
- ``openDirectory(atPath:options:)``
