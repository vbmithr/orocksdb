#!/usr/bin/env bash
set -x
echo $(gcc --version)

VERSION=4.3.1
shared_lib_file="/usr/local/lib/librocksdb.so.${VERSION}"
if [ -e $shared_lib_file ]; then
    echo "$shared_lib_file exists"
else
    echo "cloning, building, installing rocksdb"
    git clone https://github.com/facebook/rocksdb/
    cd rocksdb
    git checkout tags/rocksdb-${VERSION}
    PORTABLE=1 DEBUG_LEVEL=1 make librocksdb.so
    sudo make install-shared
    sudo ldconfig
fi
