#!/bin/bash -e

function realpath() {
    [[ $1 = /* ]] && echo "$1" || echo "$PWD/${1#./}"
}

function usage() {
  echo "$0 [Debug|Release] [clean]"
  exit 1
}

if [ "${1}" == "-h" ]
then
  usage
fi

TYPE=$1
if [ -z "$TYPE" ]
then
  TYPE=Debug
fi

if [ "${TYPE}" != "Debug" -a "${TYPE}" != "Release" ]
then
  usage
fi

CLEAN=$2

# Clone and build libjpeg-turbo
if git clone https://github.com/libjpeg-turbo/libjpeg-turbo.git
then
  pushd libjpeg-turbo
  git checkout 2.0.5

  patch -p1 < ../libjpeg-turbo.patch
  mkdir -p build_iphoneos
  pushd build_iphoneos
  cmake -G"Unix Makefiles" -DCMAKE_TOOLCHAIN_FILE=../../ios-cmake/ios.toolchain.cmake \
        -DPLATFORM=OS64 -DDEPLOYMENT_TARGET=12.0 -DCMAKE_INSTALL_PREFIX=./libs \
        -DENABLE_BITCODE=OFF -DENABLE_VISIBILITY=ON -DENABLE_ARC=OFF ..
  make -j 12
  popd

  mkdir -p build_maccatalyst
  pushd build_maccatalyst
  while ! cmake -G"Unix Makefiles" -DCMAKE_TOOLCHAIN_FILE=../../ios-cmake/ios.toolchain.cmake \
        -DPLATFORM=MAC_CATALYST -DDEPLOYMENT_TARGET=10.15 \
        -DCMAKE_CXX_FLAGS_MAC_CATALYST:STRING="-target x86_64-apple-ios13.2-macabi" \
        -DCMAKE_C_FLAGS_MAC_CATALYST:STRING="-target x86_64-apple-ios13.2-macabi" \
        -DCMAKE_BUILD_TYPE=MAC_CATALYST -DCMAKE_INSTALL_PREFIX=./libs \
        -DENABLE_BITCODE=OFF -DENABLE_VISIBILITY=ON -DENABLE_ARC=OFF ..
  do
    echo "Retrying Mac Catalyst cmake config"
    sleep 2
  done
  make -j 12
  popd

  popd
fi

mkdir -p libjpeg-turbo/libs_combined/lib/ libjpeg-turbo/libs_combined/include
cp libjpeg-turbo/build_iphoneos/jconfig.h libjpeg-turbo/*.h libjpeg-turbo/libs_combined/include/
for lib in libturbojpeg.a
do
  lipo libjpeg-turbo/build_maccatalyst/libturbojpeg.a libjpeg-turbo/build_iphoneos/libturbojpeg.a\
      -output libjpeg-turbo/libs_combined/lib/libjpeg.a -create 
done
rsync -avP libjpeg-turbo/libs_combined/ ./bVNC.xcodeproj/libs_combined/

echo
echo
echo "Checking whether there are links for the patch version e.g. 10.15.6 of Mac OS X present here in the form MacOSX10.15.7.sdk -> MacOSX.sdk"
echo "If you do not, OpenSSL build for Mac Catalyst and Xcode builds may fail."
echo
echo
if ! ls -1d /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.[0-9]*.[0-9]*.sdk
then
  SDK_VERSION=$(xcrun --show-sdk-version)
  echo "It seems you are missing some symlinks of the form MacOSX${SDK_VERSION}.sdk -> MacOSX.sdk in"
  echo "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/"
  ls -l /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/
  echo "Should we make a symlink automatically? Type y and hit enter for yes, any other key for no."
  read response
  if [ "${response}" == "y" ]
  then
    pushd /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/
    sudo ln -s MacOSX.sdk MacOSX${SDK_VERSION}.sdk
    popd
  fi
  echo
  echo
fi
sleep 2

# Clone and build libssh2
if git clone https://github.com/Jan-E/iSSH2.git
then
  pushd iSSH2
  git checkout catalyst
  patch -p1 < ../iSSH2.patch
  ./catalyst.sh
  popd
else
  echo "Found libssh2 directory, assuming it is built, please remove with 'rm -rf iSSH2' to rebuild"
fi

# Copy SSH libs and header files to project
rsync -avP iSSH2/libssh2_iphoneos/ ./bVNC.xcodeproj/libs_combined/
rsync -avP iSSH2/openssl_iphoneos/ ./bVNC.xcodeproj/libs_combined/

if git clone https://github.com/leetal/ios-cmake.git
then
  pushd ios-cmake
  patch -p1 < ../ios-cmake.patch
  popd
fi

git clone https://github.com/iiordanov/libvncserver.git || true

pushd libvncserver/

if [ -n "${CLEAN}" ]
then
  rm -rf build_simulator64
fi

if [ -n "${SIMULATOR_BUILD}" -a ! -d build_simulator64 ]
then
  echo "Simulator build"

  if [ ! -d build_simulator64 ]
  then
    mkdir -p build_simulator64
    pushd build_simulator64
    cmake .. -G"Unix Makefiles" -DENABLE_BITCODE=OFF -DARCHS='x86_64' \
        -DCMAKE_TOOLCHAIN_FILE=$(realpath ../../ios-cmake/ios.toolchain.cmake) \
        -DCMAKE_C_FLAGS='-D OPENSSL_MIN_API=0x00908000L -D OPENSSL_API_COMPAT=0x00908000L' \
        -DOPENSSL_SSL_LIBRARY=$(realpath ../../iSSH2/openssl_iphoneos/lib/libssl.a) \
        -DOPENSSL_CRYPTO_LIBRARY=$(realpath ../../iSSH2/openssl_iphoneos/lib/libcrypto.a) \
        -DOPENSSL_INCLUDE_DIR=$(realpath ../../iSSH2/openssl_iphoneos/include) \
        -DCMAKE_INSTALL_PREFIX=./libs \
        -DPLATFORM=SIMULATOR64 \
        -DBUILD_SHARED_LIBS=OFF -DENABLE_VISIBILITY=ON -DENABLE_ARC=OFF \
        -DDEPLOYMENT_TARGET=12.0 \
        -DLIBVNCSERVER_HAVE_ENDIAN_H=OFF \
        -DWITH_GCRYPT=OFF \
        -DCMAKE_PREFIX_PATH=$(realpath ../../libjpeg-turbo/libs_combined/)
     popd
  fi
  pushd build_simulator64
  cmake --build . --config ${TYPE} --target install || true
  popd
fi

if [ -n "${CLEAN}" ]
then
  rm -rf build_iphone
fi

echo 'PRODUCT_BUNDLE_IDENTIFIER = com.iiordanov.bVNC' > ${TYPE}.xcconfig
if [ -z "${SIMULATOR_BUILD}" ]
then
  echo "Non-simulator build"

  if [ ! -d build_iphone ]
  then
    mkdir -p build_iphone
    pushd build_iphone
    cmake .. -G"Unix Makefiles" -DARCHS='arm64' \
        -DCMAKE_TOOLCHAIN_FILE=$(realpath ../../ios-cmake/ios.toolchain.cmake) \
        -DPLATFORM=OS64 \
        -DDEPLOYMENT_TARGET=12.0 \
        -DENABLE_BITCODE=OFF \
        -DOPENSSL_SSL_LIBRARY=$(realpath ../../iSSH2/openssl_iphoneos/lib/libssl.a) \
        -DOPENSSL_CRYPTO_LIBRARY=$(realpath ../../iSSH2/openssl_iphoneos/lib/libcrypto.a) \
        -DOPENSSL_INCLUDE_DIR=$(realpath ../../iSSH2/openssl_iphoneos/include) \
        -DCMAKE_INSTALL_PREFIX=./libs \
        -DBUILD_SHARED_LIBS=OFF \
        -DENABLE_VISIBILITY=ON \
        -DENABLE_ARC=OFF \
        -DWITH_SASL=OFF \
        -DLIBVNCSERVER_HAVE_ENDIAN_H=OFF \
        -DWITH_GCRYPT=OFF \
        -DCMAKE_PREFIX_PATH=$(realpath ../../libjpeg-turbo/libs_combined/)
    popd
  fi
  pushd build_iphone
  make -j 12
  make install
  popd

  if [ ! -d build_maccatalyst ]
  then
    mkdir -p build_maccatalyst
    pushd build_maccatalyst
    cmake .. -G"Unix Makefiles" -DARCHS='x86_64' \
        -DCMAKE_TOOLCHAIN_FILE=$(realpath ../../ios-cmake/ios.toolchain.cmake) \
        -DPLATFORM=MAC_CATALYST \
        -DDEPLOYMENT_TARGET=10.15 \
        -DCMAKE_CXX_FLAGS_MAC_CATALYST:STRING="-target x86_64-apple-ios13.2-macabi" \
        -DCMAKE_C_FLAGS_MAC_CATALYST:STRING="-target x86_64-apple-ios13.2-macabi" \
        -DCMAKE_BUILD_TYPE=MAC_CATALYST \
        -DENABLE_BITCODE=OFF \
        -DOPENSSL_SSL_LIBRARY=$(realpath ../../iSSH2/openssl_iphoneos/lib/libssl.a) \
        -DOPENSSL_CRYPTO_LIBRARY=$(realpath ../../iSSH2/openssl_iphoneos/lib/libcrypto.a) \
        -DOPENSSL_INCLUDE_DIR=$(realpath ../../iSSH2/openssl_iphoneos/include) \
        -DCMAKE_INSTALL_PREFIX=./libs \
        -DBUILD_SHARED_LIBS=OFF \
        -DENABLE_VISIBILITY=ON \
        -DENABLE_ARC=OFF \
        -DWITH_SASL=OFF \
        -DLIBVNCSERVER_HAVE_ENDIAN_H=OFF \
        -DWITH_GCRYPT=OFF \
        -DCMAKE_PREFIX_PATH=$(realpath ../../libjpeg-turbo/libs_combined/)
    popd
  fi
  pushd build_maccatalyst
  make -j 12
  make install
  popd
fi

rsync -avP build_iphone/libs/ libs_combined/
pushd libs_combined

for lib in lib/lib*.a
do
  echo $lib
  if [ -z "${SIMULATOR_BUILD}" ]
  then
    lipo ../build_maccatalyst/libs/${lib} ../build_iphone/libs/${lib} -output ${lib} -create
  else
    lipo ../build_simulator64/libs/${lib} -output ${lib} -create
  fi
done

popd

popd

rsync -avPL libvncserver/libs_combined/lib libvncserver/libs_combined/include bVNC.xcodeproj/libs_combined/

# Make a super duper static lib out of all the other libs
pushd bVNC.xcodeproj/libs_combined/lib
/Library/Developer/CommandLineTools/usr/bin//libtool -static -o superlib.a libcrypto.a libssh2.a libssl.a libturbojpeg.a libvncclient.a
popd
