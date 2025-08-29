# ``NIOFileSystem/FileSystemProtocol``

## Topics

### Opening files with managed lifecycles

Files and directories can be opened and have their lifecycles managed by using the
following methods:

- ``withFileHandle(forReadingAt:options:execute:)-nsue``
- ``withFileHandle(forWritingAt:options:execute:)-1p6ka``
- ``withFileHandle(forReadingAndWritingAt:options:execute:)-9nqu3``
- ``withDirectoryHandle(atPath:options:execute:)-4wzzz``

### Opening files

Files and directories can be opened using the following methods. The caller is responsible for
closing it to avoid leaking resources.

- ``openFile(forReadingAt:)-6v2b8``
- ``openFile(forWritingAt:options:)``
- ``openFile(forReadingAndWritingAt:options:)``
- ``openDirectory(atPath:options:)``

### File information

- ``info(forFileAt:infoAboutSymbolicLink:)``

### Symbolic links

- ``createSymbolicLink(at:withDestination:)``
- ``destinationOfSymbolicLink(at:)``

### Managing files

- ``copyItem(at:to:strategy:shouldProceedAfterError:shouldCopyItem:)``
- ``removeItem(at:)-1vii4``
- ``moveItem(at:to:)``
- ``replaceItem(at:withItemAt:)``
- ``createDirectory(at:withIntermediateDirectories:permissions:)``

### System directories

- ``currentWorkingDirectory``
- ``temporaryDirectory``
- ``withTemporaryDirectory(prefix:options:execute:)-rbkk``
