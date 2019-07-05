add_library(CNIOSHA1 STATIC c_nio_sha1.c)
target_include_directories(CNIOSHA1 PUBLIC $<BUILD_INTERFACE:${CMAKE_CURRENT_LIST_DIR}/include>)
