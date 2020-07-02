add_library(CNIOWindows STATIC
  shim.c)
target_include_directories(CNIOWindows PUBLIC
  include)
