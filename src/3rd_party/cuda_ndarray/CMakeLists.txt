ADD_DEFINITIONS(-DTHEANO_KERN_WID=0)



# no support for python 3 yet
SET(Python_ADDITIONAL_VERSIONS 2.6 2.7)
find_package (PythonLibs REQUIRED)
if (PYTHONLIBS_FOUND )
    include_directories(${PYTHON_INCLUDE_DIRS} )
endif(PYTHONLIBS_FOUND )

CUDA_ADD_LIBRARY("tp_theano${LIB_SUFFIX}" SHARED
   convolutions.cu
   cuda_ndarray.cu
 )


if (PYTHONLIBS_FOUND )
    TARGET_LINK_LIBRARIES("tp_theano${LIB_SUFFIX}" ${PYTHON_LIBRARIES})
endif(PYTHONLIBS_FOUND )

install(TARGETS "tp_theano${LIB_SUFFIX}"
   RUNTIME DESTINATION bin
   LIBRARY DESTINATION lib
   ARCHIVE DESTINATION lib/static)
