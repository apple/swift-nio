# ``_NIOFileSystem/FileSystemProtocol``

## Topics

### Opening files with managed lifecycles

Files and directories can be opened and have their lifecycles managed by using the
following methods:

- ``withFileHandle(forReadingAt:options:execute:)-(NIOFilePath,_,_)``
- ``withFileHandle(forWritingAt:options:execute:)-(NIOFilePath,_,_)``
- ``withFileHandle(forReadingAndWritingAt:options:execute:)-(NIOFilePath,_,_)``
- ``withDirectoryHandle(atPath:options:execute:)-(NIOFilePath,_,_)``

### Opening files

Files and directories can be opened using the following methods. The caller is responsible for
closing it to avoid leaking resources.

- ``openFile(forReadingAt:)-(NIOFilePath)``
- ``openFile(forWritingAt:options:)-(NIOFilePath,_)``
- ``openFile(forReadingAndWritingAt:options:)-(NIOFilePath,_)``
- ``openDirectory(atPath:options:)-(NIOFilePath,_)``

### File information

- ``info(forFileAt:infoAboutSymbolicLink:)-(NIOFilePath,_)``

### Symbolic links

- ``createSymbolicLink(at:withDestination:)-(NIOFilePath,_)``
- ``destinationOfSymbolicLink(at:)->NIOFilePath``

### Managing files

- ``copyItem(at:to:strategy:shouldProceedAfterError:shouldCopyItem:)-(NIOFilePath,_,_,_,_)``
- ``removeItem(at:)-(NIOFilePath)``
- ``moveItem(at:to:)-(NIOFilePath,_)``
- ``replaceItem(at:withItemAt:)-(NIOFilePath,_)``
- ``createDirectory(at:withIntermediateDirectories:permissions:)-(NIOFilePath,_,_)``

### System directories

- ``currentWorkingDirectory``
- ``temporaryDirectory``
- ``withTemporaryDirectory(prefix:options:execute:)-(NIOFilePath?,_,_)``
