// snippet.hide

import NIOCore
import _NIOFileSystem

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
func main() async throws {
    // snippet.show

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
        print("Plan for Dave's demise:", String(decoding: plan.readableBytesView, as: UTF8.self))
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
            if entry.name == "daisy.mp3" {
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
    // snippet.end
}
