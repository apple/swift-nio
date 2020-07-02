add_library(CNIODarwin STATIC
  shim.c)
target_include_directories(CNIODarwin PUBLIC
  include)
