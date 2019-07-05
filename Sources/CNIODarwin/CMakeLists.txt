add_library(CNIODarwin STATIC shim.c)
target_include_directories(CNIODarwin PUBLIC $<BUILD_INTERFACE:${CMAKE_CURRENT_LIST_DIR}/include>)
