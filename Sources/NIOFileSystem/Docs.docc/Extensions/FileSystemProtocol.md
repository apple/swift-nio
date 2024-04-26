# ``_NIOFileSystem/FileSystemProtocol``

## Topics

### Opening files with managed lifecycles

Files and directories can be opened and have their lifecycles managed by using the
following methods:

- ``withFileHandle(forReadingAt:options:execute:)``
- ``withFileHandle(forWritingAt:options:execute:)``
- ``withFileHandle(forReadingAndWritingAt:options:execute:)``
- ``withDirectoryHandle(atPath:options:execute:)``

### Opening files

Files and directories can be opened using the following methods. The caller is responsible for
closing it to avoid leaking resources.

- ``openFile(forReadingAt:)``
- ``openFile(forWritingAt:options:)``
- ``openFile(forReadingAndWritingAt:options:)``
- ``openDirectory(atPath:options:)``

### File information

- ``info(forFileAt:infoAboutSymbolicLink:)``

### Symbolic links

- ``createSymbolicLink(at:withDestination:)``
- ``destinationOfSymbolicLink(at:)``

### Managing files

- ``copyItem(at:to:shouldProceedAfterError:shouldCopyFile:)``
- ``removeItem(at:)``
- ``moveItem(at:to:)``
- ``replaceItem(at:withItemAt:)``
- ``createDirectory(at:withIntermediateDirectories:permissions:)``

### System directories

- ``currentWorkingDirectory``
- ``temporaryDirectory``
- ``withTemporaryDirectory(prefix:options:execute:)``
