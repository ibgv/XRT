if (NOT WIN32)

set(XRT_SETUP_SCRIPTS
  setup.sh
  setup.csh)

set(XRT_LOADER_SCRIPTS
  loader)

set (XRT_SCRIPTS
  xrtdeps.sh
  plp_program.sh)

set(XBRESET
  _scflash.py
  _xbreset.py)
else()

set(XRT_SETUP_SCRIPTS
  setup.bat)

set (XRT_LOADER_SCRIPTS
  loader.bat)

endif(NOT WIN32)

install (PROGRAMS ${XRT_SCRIPTS} DESTINATION ${XRT_INSTALL_BIN_DIR})
install (PROGRAMS ${XRT_LOADER_SCRIPTS} DESTINATION ${XRT_INSTALL_UNWRAPPED_DIR})
install (FILES ${XRT_SETUP_SCRIPTS} DESTINATION ${XRT_INSTALL_DIR})
install (FILES ${XBRESET} DESTINATION ${XRT_INSTALL_UNWRAPPED_DIR})
