# ``_NIOFileSystem/FileHandleProtocol``

## Topics

### File Information

- ``info()``

### Permissions

- ``replacePermissions(_:)``
- ``addPermissions(_:)``
- ``removePermissions(_:)``

### Extended Attributes

- ``attributeNames()``
- ``valueForAttribute(_:)``
- ``updateValueForAttribute(_:attribute:)``
- ``removeValueForAttribute(_:)``

### Descriptor Management

- ``synchronize()``
- ``withUnsafeDescriptor(_:)``
- ``detachUnsafeFileDescriptor()``
- ``close()``
