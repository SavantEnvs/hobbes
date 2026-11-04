# Included via CMAKE_PROJECT_hobbes_INCLUDE: hobbes appends -Werror after CMAKE_CXX_FLAGS on Linux, so a
# warning new to clang 19 would otherwise fail the build. add_compile_options lands after it.
add_compile_options(-Wno-error -Wno-error=old-style-cast)
