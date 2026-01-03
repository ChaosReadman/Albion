#include <tinyxml2.h>
#include <iostream>
#include <fstream>
#include <sys/stat.h>
#include <sys/types.h>
#include <string>
#include <vector>

using namespace tinyxml2;
using namespace std;

// ディレクトリ作成ヘルパー
void make_dir(const string& path) {
#ifdef _WIN32
    _mkdir(path.c_str());
#else
    mkdir(path.c_str(), 0755);
#endif
}

// ファイル書き込みヘルパー
void write_file(const string& path, const string& content) {
    ofstream out(path, ios::binary);
    out << content;
    out.close();
}

// 再帰的に要素を処理
void process_element(XMLElement* el, string basePath, int index) {
    // ディレクトリ名: Index_TagName
    string dirName = to_string(index) + "_" + el->Name();
    string currentPath = basePath + "/" + dirName;
    make_dir(currentPath);

    // 属性の保存 (attr.txt)
    string attrContent = "";
    for (const XMLAttribute* a = el->FirstAttribute(); a; a = a->Next()) {
        attrContent += string(a->Name()) + "=" + string(a->Value()) + "\r\n";
    }
    if (!attrContent.empty()) {
        write_file(currentPath + "/attr.txt", attrContent);
    }

    // テキストの保存 (inner.txt)
    if (el->GetText()) {
        write_file(currentPath + "/inner.txt", el->GetText());
    }

    // 子要素の処理
    int childIndex = 0;
    for (XMLElement* child = el->FirstChildElement(); child; child = child->NextSiblingElement()) {
        process_element(child, currentPath, childIndex++);
    }
}

int main(int argc, char* argv[]) {
    if (argc < 3) {
        cerr << "Usage: " << argv[0] << " <xml file> <target folder>" << endl;
        return 1;
    }
    string xmlFile = argv[1];
    string targetDir = argv[2];

    XMLDocument doc;
    if (doc.LoadFile(xmlFile.c_str()) != XML_SUCCESS) {
        cerr << "Failed to load XML file: " << xmlFile << endl;
        return 1;
    }

    // ターゲットディレクトリを作成
    make_dir(targetDir);
    
    XMLElement* root = doc.RootElement();
    if (root) {
        // ルート要素から再帰処理開始
        process_element(root, targetDir, 0);
    } else {
        cerr << "Warning: XML is empty." << endl;
    }

    cout << "Converted " << xmlFile << " to " << targetDir << endl;
    return 0;
}