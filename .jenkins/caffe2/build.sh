#!/bin/bash

set -ex

# TODO: Migrate all centos jobs to use proper devtoolset
if [[ "$BUILD_ENVIRONMENT" == "py2-cuda9.0-cudnn7-centos7" ]]; then
  # There is a bug in pango packge on Centos7 that causes undefined
  # symbols, upgrading glib2 to >=2.56.1 solves the issue. See
  # https://bugs.centos.org/view.php?id=15495
  sudo yum install -y -q glib2-2.56.1
fi

pip install --user --no-cache-dir hypothesis==3.59.0

# The INSTALL_PREFIX here must match up with test.sh
INSTALL_PREFIX="/usr/local/caffe2"
LOCAL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$LOCAL_DIR"/../.. && pwd)
CMAKE_ARGS=()
SCCACHE="$(which sccache)"

if [ "$(which gcc)" != "/root/sccache/gcc" ]; then
  # Setup SCCACHE
  ###############################################################################
  # Setup sccache if SCCACHE_BUCKET is set
  if [ -n "${SCCACHE_BUCKET}" ]; then
    mkdir -p ./sccache

    SCCACHE="$(which sccache)"
    if [ -z "${SCCACHE}" ]; then
      echo "Unable to find sccache..."
      exit 1
    fi

    # Setup wrapper scripts
    wrapped="cc c++ gcc g++ x86_64-linux-gnu-gcc"
    if [[ "${BUILD_ENVIRONMENT}" == *-cuda* ]]; then
        wrapped="$wrapped nvcc"
    fi
    for compiler in $wrapped; do
      (
        echo "#!/bin/sh"

        # TODO: if/when sccache gains native support for an
        # SCCACHE_DISABLE flag analogous to ccache's CCACHE_DISABLE,
        # this can be removed. Alternatively, this can be removed when
        # https://github.com/pytorch/pytorch/issues/13362 is fixed.
        #
        # NOTE: carefully quoted - we want `which compiler` to be
        # resolved as we execute the script, but SCCACHE_DISABLE and
        # $@ to be evaluated when we execute the script
        echo 'test $SCCACHE_DISABLE && exec '"$(which $compiler)"' "$@"'

        echo "exec $SCCACHE $(which $compiler) \"\$@\""
      ) > "./sccache/$compiler"
      chmod +x "./sccache/$compiler"
    done

    export CACHE_WRAPPER_DIR="$PWD/sccache"

    # CMake must find these wrapper scripts
    export PATH="$CACHE_WRAPPER_DIR:$PATH"
  fi
fi

# Setup ccache if configured to use it (and not sccache)
if [ -z "${SCCACHE}" ] && which ccache > /dev/null; then
  mkdir -p ./ccache
  ln -sf "$(which ccache)" ./ccache/cc
  ln -sf "$(which ccache)" ./ccache/c++
  ln -sf "$(which ccache)" ./ccache/gcc
  ln -sf "$(which ccache)" ./ccache/g++
  ln -sf "$(which ccache)" ./ccache/x86_64-linux-gnu-gcc
  if [[ "${BUILD_ENVIRONMENT}" == *-cuda* ]]; then
    ln -sf "$(which ccache)" ./ccache/nvcc
  fi
  export CACHE_WRAPPER_DIR="$PWD/ccache"
  export PATH="$CACHE_WRAPPER_DIR:$PATH"
fi

# sccache will fail for CUDA builds if all cores are used for compiling
if [ -z "$MAX_JOBS" ]; then
  if [[ "${BUILD_ENVIRONMENT}" == *-cuda* ]] && [ -n "${SCCACHE}" ]; then
    MAX_JOBS=`expr $(nproc) - 1`
  else
    MAX_JOBS=$(nproc)
  fi
fi

report_compile_cache_stats() {
  if [[ -n "${SCCACHE}" ]]; then
    "$SCCACHE" --show-stats
  elif which ccache > /dev/null; then
    ccache -s
  fi
}

###############################################################################
# Explicitly set Python executable.
###############################################################################
# On Ubuntu 16.04 the default Python is still 2.7.
PYTHON="$(which python)"
if [[ "${BUILD_ENVIRONMENT}" =~ py((2|3)\.?[0-9]?\.?[0-9]?) ]]; then
  PYTHON=$(which "python${BASH_REMATCH[1]}")
  CMAKE_ARGS+=("-DPYTHON_EXECUTABLE=${PYTHON}")
fi


###############################################################################
# Use special scripts for Android and setup builds
###############################################################################
if [[ "${BUILD_ENVIRONMENT}" == *-android* ]]; then
  export ANDROID_NDK=/opt/ndk
  CMAKE_ARGS+=("-DBUILD_BINARY=ON")
  CMAKE_ARGS+=("-DBUILD_TEST=ON")
  CMAKE_ARGS+=("-DUSE_OBSERVERS=ON")
  CMAKE_ARGS+=("-DUSE_ZSTD=ON")
  "${ROOT_DIR}/scripts/build_android.sh" ${CMAKE_ARGS[*]} "$@"
  exit 0
fi


###############################################################################
# Set cmake args
###############################################################################
CMAKE_ARGS+=("-DBUILD_BINARY=ON")
CMAKE_ARGS+=("-DBUILD_TEST=ON")
CMAKE_ARGS+=("-DINSTALL_TEST=ON")
CMAKE_ARGS+=("-DUSE_OBSERVERS=ON")
CMAKE_ARGS+=("-DUSE_ZSTD=ON")
CMAKE_ARGS+=("-DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX}")

if [[ $BUILD_ENVIRONMENT == *mkl* ]]; then
  CMAKE_ARGS+=("-DBLAS=MKL")
fi

if [[ $BUILD_ENVIRONMENT == py2-cuda9.0-cudnn7-ubuntu16.04 ]]; then

  # removing http:// duplicate in favor of nvidia-ml.list
  # which is https:// version of the same repo
  sudo rm -f /etc/apt/sources.list.d/nvidia-machine-learning.list
  curl -o ./nvinfer-runtime-trt-repo-ubuntu1604-5.0.2-ga-cuda9.0_1-1_amd64.deb https://developer.download.nvidia.com/compute/machine-learning/repos/ubuntu1604/x86_64/nvinfer-runtime-trt-repo-ubuntu1604-5.0.2-ga-cuda9.0_1-1_amd64.deb
  sudo dpkg -i ./nvinfer-runtime-trt-repo-ubuntu1604-5.0.2-ga-cuda9.0_1-1_amd64.deb
  sudo apt-key add /var/nvinfer-runtime-trt-repo-5.0.2-ga-cuda9.0/7fa2af80.pub
  sudo apt-get -qq update
  sudo apt-get install libnvinfer5 libnvinfer-dev
  rm ./nvinfer-runtime-trt-repo-ubuntu1604-5.0.2-ga-cuda9.0_1-1_amd64.deb

  CMAKE_ARGS+=("-DUSE_TENSORRT=ON")
fi

if [[ $BUILD_ENVIRONMENT == *cuda* ]]; then
  CMAKE_ARGS+=("-DUSE_CUDA=ON")
  CMAKE_ARGS+=("-DCUDA_ARCH_NAME=Maxwell")
  CMAKE_ARGS+=("-DUSE_NNPACK=OFF")

  # Explicitly set path to NVCC such that the symlink to ccache or sccache is used
  CMAKE_ARGS+=("-DCUDA_NVCC_EXECUTABLE=${CACHE_WRAPPER_DIR}/nvcc")

  # Ensure FindCUDA.cmake can infer the right path to the CUDA toolkit.
  # Setting PATH to resolve to the right nvcc alone isn't enough.
  # See /usr/share/cmake-3.5/Modules/FindCUDA.cmake, block at line 589.
  export CUDA_PATH="/usr/local/cuda"

  # Ensure the ccache symlink can still find the real nvcc binary.
  export PATH="/usr/local/cuda/bin:$PATH"
fi
if [[ $BUILD_ENVIRONMENT == *rocm* ]]; then
  # This is needed to enable ImageInput operator in resnet50_trainer
  CMAKE_ARGS+=("-USE_OPENCV=ON")
  # This is needed to read datasets from https://download.caffe2.ai/databases/resnet_trainer.zip
  CMAKE_ARGS+=("-USE_LMDB=ON")

  ########## HIPIFY Caffe2 operators
  ${PYTHON} "${ROOT_DIR}/tools/amd_build/build_amd.py"
fi

# building bundled nccl in this config triggers a bug in nvlink. For
# more, see https://github.com/pytorch/pytorch/issues/14486
if [[ "${BUILD_ENVIRONMENT}" == *-cuda8*-cudnn7* ]]; then
    CMAKE_ARGS+=("-DUSE_SYSTEM_NCCL=ON")
fi

# Try to include Redis support for Linux builds
if [ "$(uname)" == "Linux" ]; then
  CMAKE_ARGS+=("-DUSE_REDIS=ON")
fi

# Currently, on Jenkins mac os, we will use custom protobuf. Mac OS
# contbuild at the moment is minimal dependency - it doesn't use glog
# or gflags either.
if [ "$(uname)" == "Darwin" ]; then
  CMAKE_ARGS+=("-DBUILD_CUSTOM_PROTOBUF=ON")
fi

# Use a speciallized onnx namespace in CI to catch hardcoded onnx namespace
CMAKE_ARGS+=("-DONNX_NAMESPACE=ONNX_NAMESPACE_FOR_C2_CI")

# We test the presence of cmake3 (for platforms like Centos and Ubuntu 14.04)
# and use that if so.
if [[ -x "$(command -v cmake3)" ]]; then
    CMAKE_BINARY=cmake3
else
    CMAKE_BINARY=cmake
fi

###############################################################################
# Configure and make
###############################################################################

if [[ -z "$INTEGRATED" ]]; then

  # Run cmake from ./build_caffe2 directory so it doesn't conflict with
  # standard PyTorch build directory. Eventually these won't need to
  # be separate.
  rm -rf build_caffe2
  mkdir build_caffe2
  cd ./build_caffe2

  # Configure
  ${CMAKE_BINARY} "${ROOT_DIR}" ${CMAKE_ARGS[*]} "$@"

  # Build
  if [ "$(uname)" == "Linux" ]; then
    make "-j${MAX_JOBS}" install
  else
    echo "Don't know how to build on $(uname)"
    exit 1
  fi

  # This is to save test binaries for testing
  mv "$INSTALL_PREFIX/test/" "$INSTALL_PREFIX/cpp_test/"

  ls $INSTALL_PREFIX

else

  # sccache will be stuck if  all cores are used for compiling
  # see https://github.com/pytorch/pytorch/pull/7361
  if [[ -n "${SCCACHE}" ]]; then
    export MAX_JOBS=`expr $(nproc) - 1`
  fi

  USE_LEVELDB=1 USE_LMDB=1 USE_OPENCV=1 BUILD_TEST=1 BUILD_BINARY=1 python setup.py install --user

  # This is to save test binaries for testing
  cp -r torch/lib/tmp_install $INSTALL_PREFIX
  mkdir -p "$INSTALL_PREFIX/cpp_test/"
  cp -r caffe2/test/* "$INSTALL_PREFIX/cpp_test/"

  ls $INSTALL_PREFIX

  report_compile_cache_stats
fi

###############################################################################
# Install ONNX
###############################################################################

# Install ONNX into a local directory
pip install --user -b /tmp/pip_install_onnx "file://${ROOT_DIR}/third_party/onnx#egg=onnx"

report_compile_cache_stats

# Symlink the caffe2 base python path into the system python path,
# so that we can import caffe2 without having to change $PYTHONPATH.
# Run in a subshell to contain environment set by /etc/os-release.
#
# This is only done when running on Jenkins!  We don't want to pollute
# the user environment with Python symlinks and ld.so.conf.d hacks.
#
if [[ -z "$INTEGRATED" ]]; then
  if [ -n "${JENKINS_URL}" ]; then
    (
      source /etc/os-release

      function python_version() {
        "$PYTHON" -c 'import sys; print("python%d.%d" % sys.version_info[0:2])'
      }

      # Debian/Ubuntu
      if [[ "$ID_LIKE" == *debian* ]]; then
        python_path="/usr/local/lib/$(python_version)/dist-packages"
        sudo ln -sf "${INSTALL_PREFIX}/caffe2" "${python_path}"
      fi

      # RHEL/CentOS
      if [[ "$ID_LIKE" == *rhel* ]]; then
        python_path="/usr/lib64/$(python_version)/site-packages/"
        sudo ln -sf "${INSTALL_PREFIX}/caffe2" "${python_path}"
      fi

      # /etc/ld.so.conf.d is used on both Debian and RHEL
      echo "${INSTALL_PREFIX}/lib" | sudo tee /etc/ld.so.conf.d/caffe2.conf
      sudo ldconfig
    )
  fi
fi
