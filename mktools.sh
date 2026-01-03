# loadxml2mnt のコンパイル
g++ loadxml2mnt.cpp -o loadxml2mnt -ltinyxml2

# fuseMount のコンパイル
g++ fuseMount.cpp -o fuseMount -D_FILE_OFFSET_BITS=64 -lfuse -ltinyxml2
