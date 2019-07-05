set(HTTP_TESTS
  test_01_get_file.sh
  test_02_get_random_bytes.sh
  test_03_post_random_bytes.sh
  test_04_keep_alive_works.sh
  test_05_repeated_reqs_work.sh
  test_06_http_1.0.sh
  test_07_headers_work.sh
  test_08_survive_signals.sh
  test_09_curl_happy_with_trailers.sh
  test_10_connection_drop_in_body_ok.sh
  test_11_res_body_streaming.sh
  test_12_headers_too_large.sh
  test_13_http_pipelining.sh
  test_14_strict_mode_assertion.sh
  test_15_post_in_chunked_encoding.sh
  test_16_tcp_client_ip.sh
  test_17_serve_massive_sparse_file.sh
  test_18_close_with_no_keepalive.sh
  test_19_connection_drop_while_waiting_for_response_uds.sh
  test_20_connection_drop_while_waiting_for_response_tcp.sh
  test_21_connection_reset_tcp.sh
  test_22_http_1.0_keep_alive.sh
  test_23_repeated_reqs_with_half_closure.sh
)

foreach(http_test IN LISTS HTTP_TESTS)
  file(MAKE_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/${test})
  add_test(NAME ${http_test}
    #    COMMAND ${CMAKE_COMMAND} -E env NIOHTTP1Server_EXEC=$<TARGET_FILE:NIOHTTP1Server> ${CMAKE_CURRENT_LIST_DIR}/run-single-test.sh ${CMAKE_CURRENT_LIST_DIR}/tests_01_http/${http_test} ${CMAKE_CURRENT_BINARY_DIR}/${test} "${CMAKE_SOURCE_DIR}/.." 1
    COMMAND ${CMAKE_COMMAND} -E env NIOHTTP1Server_EXEC=$<TARGET_FILE:NIOHTTP1Server> ${CMAKE_CURRENT_LIST_DIR}/run-tests.sh -f ${http_test}

    WORKING_DIRECTORY ${CMAKE_CURRENT_LIST_DIR}
  )
#        if run_test "$here/run-single-test.sh" "$here/$f/$t" "$test_tmp" "$here/.." "$show_info"; then
endforeach()
#add_test(NAME tests_02_syscall_wrappers)
#add_test(NAME tests_03_linker_things)
#add_test(NAME tests_04_performance)
