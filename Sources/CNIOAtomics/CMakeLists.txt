add_library(CNIOAtomics STATIC
  src/c-atomics.c
)
target_include_directories(CNIOAtomics PUBLIC $<BUILD_INTERFACE:${CMAKE_CURRENT_LIST_DIR}/include>)
