add_subdirectory(NIOConcurrencyHelpersTests)
add_subdirectory(NIOFoundationCompatTests)
add_subdirectory(NIOHTTP1Tests)

add_executable(NIOTestRunner
  LinuxMain.swift)
target_link_libraries(NIOTestRunner PRIVATE
  NIOConcurrencyHelpersTests
  NIOFoundationCompatTests
  NIOHTTP1Tests)

add_test(NIOTests
  COMMAND NIOTestRunner)
