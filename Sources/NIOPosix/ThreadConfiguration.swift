#if canImport(Darwin)
import Dispatch
#endif

public struct NIOThreadConfiguration: Sendable {
    public var threadNamePrefix: Optional<String>

    #if canImport(Darwin)
    public var osSpecificConfiguration: DarwinThreadConfiguration
    #elseif os(Linux)
    public var osSpecificConfiguration: LinuxThreadConfiguration
    #elseif os(Windows)
    public var osSpecificConfiguration: WindowsThreadConfiguration
    #elseif os(Android)
    public var osSpecificConfiguration: AndroidThreadConfiguration
    #elseif os(WASI)
    public var osSpecificConfiguration: WASIThreadConfiguration
    #elseif os(FreeBSD)
    public var osSpecificConfiguration: FreeBSDThreadConfiguration
    #endif

    internal static var defaultForEventLoopGroups: Self {
        NIOThreadConfiguration(
            threadNamePrefix: "NIO-ELT-",
            osSpecificConfiguration: .default
        )
    }

    internal static var defaultForOffloadThreadPool: Self {
        NIOThreadConfiguration(
            threadNamePrefix: "TP-",
            osSpecificConfiguration: .default
        )
    }

    public static var `default`: Self {
        NIOThreadConfiguration(
            threadNamePrefix: nil,
            osSpecificConfiguration: .default
        )
    }
}

#if os(Linux)
extension NIOThreadConfiguration {
    public struct LinuxThreadConfiguration: Sendable {
        public static var `default`: Self {
            .init()
        }
    }
}
#endif

#if os(Android)
extension NIOThreadConfiguration {
    public struct AndroidThreadConfiguration: Sendable {
        public static var `default`: Self {
            .init()
        }
    }
}
#endif

#if os(Windows)
extension NIOThreadConfiguration {
    public struct WindowsThreadConfiguration: Sendable {
        public static var `default`: Self {
            .init()
        }
    }
}
#endif

#if os(WASI)
extension NIOThreadConfiguration {
    public struct WASIThreadConfiguration: Sendable {
        public static var `default`: Self {
            .init()
        }
    }
}
#endif

#if os(FreeBSD)
extension NIOThreadConfiguration {
    public struct FreeBSDThreadConfiguration: Sendable {
        public static var `default`: Self {
            .init()
        }
    }
}
#endif

#if canImport(Darwin)
extension NIOThreadConfiguration {
    public struct DarwinThreadConfiguration: Sendable {
        public var qosClass: DarwinQoSClass

        public struct DarwinQoSClass: Sendable {
            var backing: Backing

            internal enum Backing: Sendable {
                case inheritFromMainThread

                case custom(qos_class_t)
            }

            public static var inheritFromMainThread: Self {
                .init(backing: .inheritFromMainThread)
            }

            public static var userInteractive: Self {
                .init(backing: .custom(QOS_CLASS_USER_INTERACTIVE))
            }

            public static var userInitiated: Self {
                .init(backing: .custom(QOS_CLASS_USER_INITIATED))
            }

            public static var background: Self {
                .init(backing: .custom(QOS_CLASS_BACKGROUND))
            }

            public static var utility: Self {
                .init(backing: .custom(QOS_CLASS_UTILITY))
            }

            public static var unspecified: Self {
                .init(backing: .custom(QOS_CLASS_UNSPECIFIED))
            }

            public static var `default`: Self {
                .init(backing: .custom(QOS_CLASS_DEFAULT))
            }
        }

        public static var `default`: Self {
            .init(qosClass: .inheritFromMainThread)
        }
    }
}
#endif
