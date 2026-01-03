#!/bin/bash

# TinyXML2のソースコードがない場合はダウンロード
if [ ! -f "tinyxml2.cpp" ] || [ ! -f "tinyxml2.h" ]; then
    echo "Downloading tinyxml2..."
    # GitHubのrawファイルから取得 (wgetがなければcurlを使用するなど環境に合わせて調整してください)
    if command -v wget &> /dev/null; then
        wget https://raw.githubusercontent.com/leethomason/tinyxml2/master/tinyxml2.cpp
        wget https://raw.githubusercontent.com/leethomason/tinyxml2/master/tinyxml2.h
    else
        curl -O https://raw.githubusercontent.com/leethomason/tinyxml2/master/tinyxml2.cpp
        curl -O https://raw.githubusercontent.com/leethomason/tinyxml2/master/tinyxml2.h
    fi
fi

# コンパイル
echo "Compiling loadxml..."
# -I. はカレントディレクトリのヘッダファイル(tinyxml2.h)を探すために指定
g++ -o loadxml loadxml.cpp tinyxml2.cpp -I.

if [ $? -eq 0 ]; then
    echo "Build successful: ./loadxml"
else
    echo "Build failed."
    exit 1
fi
