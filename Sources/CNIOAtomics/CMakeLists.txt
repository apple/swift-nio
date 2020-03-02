add_library(CNIOAtomics STATIC
  src/c-atomics.c
  src/c-nioatomics.c)
target_include_directories(CNIOAtomics PUBLIC
  include)
