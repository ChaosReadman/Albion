#define FUSE_USE_VERSION 26

#include <fuse.h>
#include <tinyxml2.h>
#include <string>
#include <vector>
#include <sstream>
#include <iostream>
#include <cstring>
#include <cerrno>
#include <algorithm>
#include <dirent.h>
#include <sys/stat.h>
#include <fstream>

using namespace tinyxml2;
using namespace std;

// グローバルなXMLドキュメント保持用 (メモリ上のキャッシュとして利用)
static XMLDocument* g_doc = nullptr;
static string g_root_dir; // バックエンドのルートディレクトリ

// ユーティリティ: 文字列分割
vector<string> split(const string& s, char delimiter) {
    vector<string> tokens;
    string token;
    istringstream tokenStream(s);
    while (getline(tokenStream, token, delimiter)) {
        if (!token.empty()) {
            tokens.push_back(token);
        }
    }
    return tokens;
}

// ディレクトリから再帰的にXMLツリーを構築する関数
struct DirEntry {
    int index;
    string name;
    string filename;
};

bool compareEntries(const DirEntry& a, const DirEntry& b) {
    return a.index < b.index;
}

string read_file_content(const string& path) {
    ifstream in(path, ios::in | ios::binary);
    if (in) {
        string contents;
        in.seekg(0, ios::end);
        contents.resize(in.tellg());
        in.seekg(0, ios::beg);
        in.read(&contents[0], contents.size());
        in.close();
        return contents;
    }
    return "";
}

void load_recursive(const string& path, XMLNode* node) {
    DIR* dir = opendir(path.c_str());
    if (!dir) return;

    struct dirent* entry;
    vector<DirEntry> children;

    while ((entry = readdir(dir)) != NULL) {
        string name = entry->d_name;
        if (name == "." || name == "..") continue;

        string fullPath = path + "/" + name;

        if (name == "attr.txt") {
            if (auto el = node->ToElement()) {
                string content = read_file_content(fullPath);
                stringstream ss(content);
                string line;
                while (getline(ss, line)) {
                    size_t pos = line.find('=');
                    if (pos != string::npos) {
                        string key = line.substr(0, pos);
                        string val = line.substr(pos + 1);
                        if (!val.empty() && val.back() == '\r') val.pop_back();
                        el->SetAttribute(key.c_str(), val.c_str());
                    }
                }
            }
        } else if (name == "inner.txt") {
            if (auto el = node->ToElement()) {
                string content = read_file_content(fullPath);
                el->SetText(content.c_str());
            }
        } else {
            // Directory: N_TagName
            size_t pos = name.find('_');
            if (pos != string::npos) {
                try {
                    int idx = stoi(name.substr(0, pos));
                    string tagName = name.substr(pos + 1);
                    children.push_back({idx, tagName, name});
                } catch (...) {}
            }
        }
    }
    closedir(dir);

    // インデックス順にソートして追加
    sort(children.begin(), children.end(), compareEntries);
    for (const auto& child : children) {
        XMLElement* newEl = g_doc->NewElement(child.name.c_str());
        node->InsertEndChild(newEl);
        load_recursive(path + "/" + child.filename, newEl);
    }
}

// パス解析の結果を保持する構造体
struct PathResult {
    XMLElement* element = nullptr;
    string fileType; // "DIR", "attr.txt", "inner.txt", or "ROOT"
    bool exists = false;
};

// パスからXML要素を特定する関数
PathResult resolve_path(const char* path) {
    PathResult result;
    string p = path;

    if (p == "/") {
        result.fileType = "ROOT";
        result.exists = true;
        return result;
    }

    vector<string> parts = split(p, '/');
    if (parts.empty()) return result;

    // ルート要素のチェック (例: 0_books)
    XMLElement* current = g_doc->RootElement();
    if (!current) return result;

    // マウント直下のディレクトリ名チェック (例: 0_books)
    string rootName = "0_" + string(current->Name());
    if (parts[0] != rootName) {
        return result; // 見つからない
    }

    // パスの残りを探索
    for (size_t i = 1; i < parts.size(); ++i) {
        string part = parts[i];

        // ファイルの場合
        if (part == "attr.txt" || part == "inner.txt") {
            if (i != parts.size() - 1) return result;
            result.element = current;
            result.fileType = part;
            result.exists = true;
            return result;
        }

        // ディレクトリ(子要素)の場合: "index_tagname" を解析
        size_t underscorePos = part.find('_');
        if (underscorePos == string::npos) return result;

        try {
            int index = stoi(part.substr(0, underscorePos));
            string tagName = part.substr(underscorePos + 1);

            // 子要素を探す
            XMLElement* child = current->FirstChildElement();
            int globalIndex = 0;
            bool found = false;
            while(child) {
                if (globalIndex == index) {
                    if (string(child->Name()) == tagName) {
                        current = child;
                        found = true;
                    }
                    break;
                }
                globalIndex++;
                child = child->NextSiblingElement();
            }

            if (!found) return result;

        } catch (...) {
            return result;
        }
    }

    // 最後まで到達したらディレクトリ
    result.element = current;
    result.fileType = "DIR";
    result.exists = true;
    return result;
}

// コンテンツ生成ヘルパー
string get_attr_content(XMLElement* element) {
    if (!element) return "";
    string content = "";
    for (const XMLAttribute* a = element->FirstAttribute(); a; a = a->Next()) {
        content += string(a->Name()) + "=" + string(a->Value()) + "\r\n";
    }
    return content;
}

string get_inner_content(XMLElement* element) {
    if (!element || !element->GetText()) return "";
    return string(element->GetText());
}

// --- FUSE Operations ---

static int xmlfs_getattr(const char* path, struct stat* stbuf) {
    memset(stbuf, 0, sizeof(struct stat));
    PathResult res = resolve_path(path);

    if (!res.exists) return -ENOENT;

    if (res.fileType == "ROOT" || res.fileType == "DIR") {
        stbuf->st_mode = S_IFDIR | 0755;
        stbuf->st_nlink = 2;
    } else if (res.fileType == "attr.txt") {
        string content = get_attr_content(res.element);
        stbuf->st_mode = S_IFREG | 0444; // Read-only (for now, write updates backing file directly)
        stbuf->st_nlink = 1;
        stbuf->st_size = content.size();
    } else if (res.fileType == "inner.txt") {
        string content = get_inner_content(res.element);
        stbuf->st_mode = S_IFREG | 0444;
        stbuf->st_nlink = 1;
        stbuf->st_size = content.size();
    }

    return 0;
}

static int xmlfs_readdir(const char* path, void* buf, fuse_fill_dir_t filler,
                         off_t offset, struct fuse_file_info* fi) {
    (void) offset; (void) fi;
    PathResult res = resolve_path(path);

    if (!res.exists || (res.fileType != "ROOT" && res.fileType != "DIR"))
        return -ENOENT;

    filler(buf, ".", NULL, 0);
    filler(buf, "..", NULL, 0);

    if (res.fileType == "ROOT") {
        XMLElement* root = g_doc->RootElement();
        if (root) {
            string name = "0_" + string(root->Name());
            filler(buf, name.c_str(), NULL, 0);
        }
        return 0;
    }

    XMLElement* element = res.element;

    if (element->FirstAttribute()) {
        filler(buf, "attr.txt", NULL, 0);
    }

    if (element->GetText()) {
        filler(buf, "inner.txt", NULL, 0);
    }

    int index = 0;
    for (XMLElement* child = element->FirstChildElement(); child; child = child->NextSiblingElement()) {
        string childName = to_string(index) + "_" + child->Name();
        filler(buf, childName.c_str(), NULL, 0);
        index++;
    }

    return 0;
}

static int xmlfs_open(const char* path, struct fuse_file_info* fi) {
    PathResult res = resolve_path(path);
    if (!res.exists || (res.fileType != "attr.txt" && res.fileType != "inner.txt"))
        return -ENOENT;
    return 0;
}

static int xmlfs_read(const char* path, char* buf, size_t size, off_t offset,
                      struct fuse_file_info* fi) {
    (void) fi;
    PathResult res = resolve_path(path);
    if (!res.exists) return -ENOENT;

    string content;
    if (res.fileType == "attr.txt") {
        content = get_attr_content(res.element);
    } else if (res.fileType == "inner.txt") {
        content = get_inner_content(res.element);
    } else {
        return -ENOENT;
    }

    if (offset < content.size()) {
        if (offset + size > content.size())
            size = content.size() - offset;
        memcpy(buf, content.c_str() + offset, size);
    } else {
        size = 0;
    }

    return size;
}

static int xmlfs_write(const char* path, const char* buf, size_t size, off_t offset, struct fuse_file_info* fi) {
    (void) fi;
    PathResult res = resolve_path(path);
    if (!res.exists) return -ENOENT;

    // attr.txt の更新処理
    if (res.fileType == "attr.txt") {
        if (offset > 0) return size;

        string data(buf, size);
        
        const XMLAttribute* attr = res.element->FirstAttribute();
        while (attr) {
            res.element->DeleteAttribute(attr->Name());
            attr = res.element->FirstAttribute();
        }

        stringstream ss(data);
        string line;
        while (getline(ss, line)) {
            if (line.empty()) continue;
            size_t pos = line.find('=');
            if (pos != string::npos) {
                string key = line.substr(0, pos);
                string val = line.substr(pos + 1);
                if (!val.empty() && val.back() == '\r') val.pop_back();
                res.element->SetAttribute(key.c_str(), val.c_str());
            }
        }

        string real_path = g_root_dir + string(path);
        ofstream out(real_path, ios::out | ios::binary | ios::trunc);
        out.write(data.c_str(), data.size());
        out.close();
        
        return size;
    }
    
    // inner.txt の更新処理
    if (res.fileType == "inner.txt") {
        if (offset > 0) return size;
        string data(buf, size);
        res.element->SetText(data.c_str());
        
        string real_path = g_root_dir + string(path);
        ofstream out(real_path, ios::out | ios::binary | ios::trunc);
        out.write(data.c_str(), data.size());
        out.close();
        
        return size;
    }

    return -EACCES;
}

static int xmlfs_truncate(const char* path, off_t size) {
    PathResult res = resolve_path(path);
    if (!res.exists) return -ENOENT;
    if (res.fileType == "attr.txt" || res.fileType == "inner.txt") {
        return 0;
    }
    return -EACCES;
}

static struct fuse_operations xmlfs_oper = {
    .getattr = xmlfs_getattr,
    .truncate = xmlfs_truncate,
    .open    = xmlfs_open,
    .read    = xmlfs_read,
    .write   = xmlfs_write,
    .readdir = xmlfs_readdir,
};

int main(int argc, char* argv[]) {
    if (argc < 2) {
        cerr << "Usage: " << argv[0] << " <mount point> [backing dir]" << endl;
        return 1;
    }

    char* mount_point = argv[1];
    
    // バックエンドディレクトリの設定 (デフォルトは "food")
    if (argc >= 3) {
        g_root_dir = argv[2];
    } else {
        g_root_dir = "food";
        cout << "Using default backing directory: " << g_root_dir << endl;
    }

    // ディレクトリ構造からXMLツリーを構築
    g_doc = new XMLDocument();
    load_recursive(g_root_dir, g_doc);

    // FUSE引数の構築
    char* fuse_argv[] = { argv[0], mount_point, "-f" }; // -f: foreground
    int fuse_argc = 3;

    return fuse_main(fuse_argc, fuse_argv, &xmlfs_oper, NULL);
}