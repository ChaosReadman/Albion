#!/bin/bash

# プロジェクトルートに移動（スクリプトの場所に関わらず）
cd "$(dirname "$0")"

echo "Cleaning up project structure..."

# 誤って配置されたファイルの削除
rm -f Sources/Package.swift
rm -f Sources/main.swift
rm -f Sources/QueryProcessor.swift
rm -f Sources/routes.swift
rm -f Sources/configure.swift
rm -f main.swift
rm -f configure.swift
rm -f routes.swift
rm -f QueryProcessor.swift

# queryRoot内の不要なSwiftファイルを削除
find queryRoot -name "*.swift" -type f -delete

# ビルドキャッシュのクリア
rm -rf .build
rm -f Package.resolved

echo "Package initialization complete."
echo "Starting server..."

# サーバーの起動
swift run Run serve --port 5000