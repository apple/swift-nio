add_library(CNIOLinux STATIC
  ifaddrs-android.c
  shim.c
)
target_include_directories(CNIOLinux PUBLIC $<BUILD_INTERFACE:${CMAKE_CURRENT_LIST_DIR}/include>)
