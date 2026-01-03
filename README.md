# コンセプト
このプロジェクトは、XMLデータをFUSEでマウントし、Swiftで自動生成されたコードを使ってWeb APIとして提供する仕組みを示すサンプルです。
# 必要なもの
- Swift 5.3以降
- libfuse (macOSの場合はosxfuse)
- Swift Package Manager (Swiftに同梱されています)
# セットアップ手順
1. リポジトリをクローンします。
```git clone ChaosReadman/Albion.git```
2. プロジェクトディレクトリに移動します。
```cd Albion```
3. 依存関係を解決します。
```swift package resolve```
4. ビルドします。
```swift build -c release```
# FUSEのセットアップ
macOSの場合、osxfuseをインストールしてください。Linuxの場合はlibfuseをインストールしてください。
# XMLデータの準備
xmldataディレクトリにXMLデータを配置してください。サンプルとして、nutrient.xmlとsample.xmlが含まれています。
# クエリの準備
queryRootディレクトリにXQueryファイルを配置してください。サンプルとして、searchfoodとnutrientsのディレクトリが含まれています。

# ツール作成
mktool.shを起動して、ツールを作成してください。

# データロードとマウント
できあがったloadxml2mntを使って、fuseをマウントします

./loadxml2mnt xmldata/sample.xml mnt
./loadxml2mnt xmldata/nutrient.xml food

# アンマウントするときは
fusermount -u mnt
fusermount -u food

# 再度マウントだけしたい場合は
./fuseMount mnt food &

# ビルドキャッシュを削除
rm -rf .build

# 再度実行（依存関係の解決とビルドが最初から行われます）
swift run Run serve --port 5000

# ブラウザでアクセス
http://localhost:5000/foodinfo/searchfood?foodname=ぶどう

http://localhost:5000/foodinfo/nutrients?id=14028

各々のリクエスト先にあるqueryRoot/searchfood/query.xqyとqueryRoot/nutrients/query.xqyからswiftコードが自動生成され、コンパイルされ、実行され、その結果がブラウザに表示されます。

