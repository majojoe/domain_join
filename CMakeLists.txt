cmake_minimum_required(VERSION 2.8.11)


install(FILES src/realmd.conf DESTINATION /etc)
install(FILES src/active_directory DESTINATION /etc/sudoers.d PERMISSIONS OWNER_READ GROUP_READ)
install(FILES src/dj_mkhomedir.conf DESTINATION /usr/share/pam-configs/)
install(FILES src/krb5.conf.unconfigured DESTINATION /etc)
install(FILES src/domain_join.sh DESTINATION bin PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE GROUP_READ GROUP_EXECUTE WORLD_READ WORLD_EXECUTE)
install(FILES src/domain_leave.sh DESTINATION bin PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE GROUP_READ GROUP_EXECUTE WORLD_READ WORLD_EXECUTE)

set(CPACK_PACKAGE_NAME "domain-join")
set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "meta package that automates domain join for ubuntu systems")
set(CPACK_PACKAGE_VERSION "0.0.1")
set(SYSTEM_ARCH "all")

set(CPACK_DEBIAN_PACKAGE_DEPENDS "realmd,sssd,sssd-tools,samba-common,packagekit,samba-common-bin,samba-libs,adcli,cifs-utils,libpam-mount,libpam-ccreds,findutils,dialog,libpam-sss,coreutils,xmlstarlet")
set(CPACK_GENERATOR "DEB")
set(PACKAGE_OS "linux")
set(CPACK_SYSTEM_NAME "${PACKAGE_OS}-amd64")
set(SYSTEM_ARCH "amd64")
set(CPACK_DEBIAN_PACKAGE_MAINTAINER "Johannes Maier <maier_jo@gmx.de>")
set(CPACK_DEBIAN_PACKAGE_CONTROL_EXTRA "${CMAKE_CURRENT_SOURCE_DIR}/src/postinst;${CMAKE_CURRENT_SOURCE_DIR}/src/prerm;${CMAKE_CURRENT_SOURCE_DIR}/src/postrm")
set(CPACK_PACKAGE_FILE_NAME "${CPACK_PACKAGE_NAME}-${CPACK_PACKAGE_VERSION}-${CPACK_DEBIAN_REVISON}${CPACK_SYSTEM_NAME}")


include(CPack)


