#!/bin/bash -e


if ! [ -d ./build ]; then
        mkdir build
fi

if ! [ -d ./dist ]; then
        mkdir dist
fi

cd build
cmake ..
make package
cp *.deb ../dist
cd ..
