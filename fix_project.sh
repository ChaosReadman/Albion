#!/bin/bash
cd "$(dirname "$0")"

echo "=== Fixing Project Structure ==="

# 1. 紛らわしいファイルの完全削除
echo "Removing confusing files in queryRoot..."
find queryRoot -name "*.swift" -type f -delete
rm -f Sources/QueryProcessor.swift

# 2. 正しい場所に QueryProcessor.swift を配置 (標準エラー出力版)
echo "Updating Sources/App/Services/QueryProcessor.swift..."
mkdir -p Sources/App/Services
cat << 'EOF' > Sources/App/Services/QueryProcessor.swift
import Vapor
import Foundation

// 即時出力用のログヘルパー (標準エラー出力を使用)
func debugLog(_ message: String) {
    if let data = "[DEBUG] \(message)\n".data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

struct QueryProcessor {
    static func run(req: Request, category: String, queryName: String) async throws -> String {
        debugLog("QueryProcessor: Processing request for \(category)/\(queryName)")

        // パス設定
        let baseDir = "/home/t_oku/xmldrive/queryRoot"
        let queryDir = "\(baseDir)/\(category)/\(queryName)"
        let xqyPath = "\(queryDir)/query.xqy"
        
        // 作業ディレクトリをクエリのあるディレクトリに変更
        let workDir = queryDir
        let swiftFile = workDir + "/query.swift"
        let binaryFile = workDir + "/query"
        
        debugLog("QueryProcessor: Paths set. XQuery: \(xqyPath), WorkDir: \(workDir)")

        // 作業ディレクトリ作成
        try FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
        
        // XQuery読み込み
        guard let xqyContent = try? String(contentsOfFile: xqyPath, encoding: .utf8) else {
            debugLog("QueryProcessor: Query file not found at \(xqyPath)")
            throw Abort(.notFound, reason: "Query file not found: \(xqyPath)")
        }
        
        // Swiftコード生成 (トランスパイル)
        debugLog("QueryProcessor: Transpiling XQuery...")
        let sourceCode = try transpile(xqy: xqyContent, req: req)
        
        // query.swift 書き出し
        try sourceCode.write(toFile: swiftFile, atomically: true, encoding: .utf8)
        debugLog("QueryProcessor: Swift source code written to \(swiftFile)")
        
        // コンパイル
        debugLog("QueryProcessor: Compiling...")
        let compile = Process()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        compile.arguments = ["swiftc", swiftFile, "-o", binaryFile]
        
        let errorPipe = Pipe()
        compile.standardError = errorPipe
        
        try compile.run()
        compile.waitUntilExit()
        
        if compile.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            debugLog("QueryProcessor: Compilation failed. Error: \(errorMessage)")
            throw Abort(.internalServerError, reason: "Compilation failed: \(errorMessage)")
        }
        debugLog("QueryProcessor: Compilation successful.")
        
        // 実行
        debugLog("QueryProcessor: Executing binary...")
        let run = Process()
        run.executableURL = URL(fileURLWithPath: binaryFile)
        let pipe = Pipe()
        run.standardOutput = pipe
        try run.run()
        run.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        debugLog("QueryProcessor: Execution finished. Output size: \(data.count) bytes")
        return String(data: data, encoding: .utf8) ?? ""
    }
    
    // 簡易XQueryトランスパイラ
    static func transpile(xqy: String, req: Request) throws -> String {
        debugLog("Transpiling: Start")
        // 1. パラメータの抽出とSwift変数定義の生成
        var paramDefs = ""
        for (key, value) in req.queryDictionary {
            paramDefs += "let \(key) = \"\(value)\"\n"
        }
        
        // 2. doc('...') の抽出
        debugLog("Transpiling: Extracting doc()...")
        let docRegex = try NSRegularExpression(pattern: #"doc\('([^']+)'\)([^\s]*)"#)
        let nsRange = NSRange(xqy.startIndex..<xqy.endIndex, in: xqy)
        guard let match = docRegex.firstMatch(in: xqy, options: [], range: nsRange) else {
            throw Abort(.internalServerError, reason: "No doc() found in XQuery")
        }
        
        guard let r1 = Range(match.range(at: 1), in: xqy),
              let r2 = Range(match.range(at: 2), in: xqy) else {
            throw Abort(.internalServerError, reason: "Regex range error in doc()")
        }
        let docName = String(xqy[r1])
        let xpathQuery = String(xqy[r2])
        
        debugLog("Transpiling: docName=\(docName), xpathQuery=\(xpathQuery)")
        
        let xmlPath = "/home/t_oku/xmldrive/\(docName)" 
        
        // 3. FLWOR式の抽出
        debugLog("Transpiling: Extracting for loop...")
        let forRegex = try NSRegularExpression(pattern: #"for\s+\$([a-zA-Z0-9_]+)\s+in"#)
        guard let forMatch = forRegex.firstMatch(in: xqy, options: [], range: nsRange) else {
             throw Abort(.internalServerError, reason: "No for loop found in XQuery")
        }
        guard let forVarRange = Range(forMatch.range(at: 1), in: xqy) else {
             throw Abort(.internalServerError, reason: "Regex range error in for loop")
        }
        let loopVar = String(xqy[forVarRange])

        debugLog("Transpiling: Extracting clauses...")
        let whereRegex = try NSRegularExpression(pattern: #"where\s+([\s\S]+?)\s+order by"#)
        let whereClause = whereRegex.firstMatch(in: xqy, options: [], range: nsRange).flatMap {
            Range($0.range(at: 1), in: xqy).map { String(xqy[$0]) }
        } ?? "true"
        
        let orderRegex = try NSRegularExpression(pattern: #"order by\s+([\s\S]+?)\s+return"#)
        let orderClause = orderRegex.firstMatch(in: xqy, options: [], range: nsRange).flatMap {
            Range($0.range(at: 1), in: xqy).map { String(xqy[$0]) }
        } ?? ""
        
        let returnRegex = try NSRegularExpression(pattern: #"return\s+([\s\S]+)"#)
        let returnClause = returnRegex.firstMatch(in: xqy, options: [], range: nsRange).flatMap {
            Range($0.range(at: 1), in: xqy).map { String(xqy[$0]) }
        } ?? ""
        
        debugLog("Transpiling: Generating Swift code...")
        
        // Helper to convert XQuery expressions to Swift
        func convertExpression(_ expr: String) -> String {
            var s = String(expr)
            s = s.replacingOccurrences(of: "contains(", with: "contains_wrapper(")
            s = s.replacingOccurrences(of: " or ", with: " || ")
            s = s.replacingOccurrences(of: " and ", with: " && ")
            s = s.replacingOccurrences(of: "$", with: "")
            
            s = s.replacingOccurrences(of: "\(loopVar)/([A-Z0-9_]+)", with: #"val(element, "$1")"#, options: .regularExpression)
            s = s.replacingOccurrences(of: "\(loopVar)/@([A-Z0-9_]+)", with: #"attr(element, "$1")"#, options: .regularExpression)
            return s
        }
        
        let swiftWhere = convertExpression(String(whereClause))
        let swiftOrder = convertExpression(String(orderClause))
        
        var swiftReturn = String(returnClause)
        swiftReturn = swiftReturn.replacingOccurrences(of: "{", with: "\\(")
        swiftReturn = swiftReturn.replacingOccurrences(of: "}", with: ")")
        swiftReturn = convertExpression(swiftReturn)
        swiftReturn = swiftReturn.replacingOccurrences(of: "/string\\(\\)", with: "", options: .regularExpression)

        let template = #"""
        import Foundation
        #if canImport(FoundationXML)
        import FoundationXML
        #endif

        func hirakata(_ s: String) -> String { return s }
        func val(_ node: XMLElement, _ name: String) -> String {
            return node.elements(forName: name).first?.stringValue ?? ""
        }
        func attr(_ node: XMLElement, _ name: String) -> String {
            return node.attribute(forName: name)?.stringValue ?? ""
        }
        func contains_wrapper(_ s1: String, _ s2: String) -> Bool {
            return s1.contains(s2)
        }
        
        func loadXMLFromDirectory(path: String) -> XMLDocument? {
            let fileManager = FileManager.default
            guard let contents = try? fileManager.contentsOfDirectory(atPath: path) else { return nil }
            guard let rootDirName = contents.first(where: { $0.starts(with: "0_") }) else { return nil }
            
            let doc = XMLDocument()
            let rootName = String(rootDirName.dropFirst(2))
            let rootElement = XMLElement(name: rootName)
            doc.setRootElement(rootElement)
            
            processDirectory(path: path + "/" + rootDirName, element: rootElement)
            return doc
        }
        
        func processDirectory(path: String, element: XMLElement) {
            let fileManager = FileManager.default
            guard let contents = try? fileManager.contentsOfDirectory(atPath: path) else { return }
            
            if contents.contains("attr.txt"), let attrContent = try? String(contentsOfFile: path + "/attr.txt", encoding: .utf8) {
                let lines = attrContent.split(separator: "\n")
                for line in lines {
                    let parts = line.split(separator: "=", maxSplits: 1)
                    if parts.count == 2 {
                        let key = String(parts[0])
                        let val = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if let attr = XMLNode.attribute(withName: key, stringValue: val) as? XMLNode {
                            element.addAttribute(attr)
                        }
                    }
                }
            }
            if contents.contains("inner.txt"), let textContent = try? String(contentsOfFile: path + "/inner.txt", encoding: .utf8) {
                if let textNode = XMLNode.text(withStringValue: textContent) as? XMLNode {
                    element.addChild(textNode)
                }
            }
            let childDirs = contents.filter { $0.contains("_") && !$0.starts(with: ".") }.sorted {
                (Int($0.split(separator: "_")[0]) ?? 0) < (Int($1.split(separator: "_")[0]) ?? 0)
            }
            for childDir in childDirs {
                let parts = childDir.split(separator: "_", maxSplits: 1)
                if parts.count == 2 {
                    let tagName = String(parts[1])
                    let childElement = XMLElement(name: tagName)
                    element.addChild(childElement)
                    processDirectory(path: path + "/" + childDir, element: childElement)
                }
            }
        }

        \#(paramDefs)
        let searchstr = hirakata(foodname)

        let xmlPath = "\#(xmlPath)"
        do {
            guard let doc = loadXMLFromDirectory(path: xmlPath) else {
                print("Error: Failed to load XML from directory")
                exit(1)
            }
            guard let root = doc.rootElement() else { 
                print("Error: No root element")
                exit(1) 
            }
            
            let nodes = try root.nodes(forXPath: "\#(xpathQuery)")
            var resultNodes: [XMLElement] = []
            
            for node in nodes {
                guard let element = node as? XMLElement else { continue }
                if \#(swiftWhere) {
                    resultNodes.append(element)
                }
            }
            
            resultNodes.sort { 
                let v1 = \#(swiftOrder.replacingOccurrences(of: "element", with: "$0"))
                let v2 = \#(swiftOrder.replacingOccurrences(of: "element", with: "$1"))
                return v1 < v2
            }
            
            for element in resultNodes {
                print("""
        \#(swiftReturn)
        """)
            }
            
        } catch {
            print("Error: \(error)")
            exit(1)
        }
        """#
        
        return template
    }
}

extension Request {
    var queryDictionary: [String: String] {
        var dict: [String: String] = [:]
        if let query = self.url.query {
            let pairs = query.split(separator: "&")
            for pair in pairs {
                let parts = pair.split(separator: "=")
                if parts.count == 2 {
                    dict[String(parts[0])] = String(parts[1]).removingPercentEncoding
                }
            }
        }
        return dict
    }
}
EOF

# 3. routes.swift も更新 (標準エラー出力版)
echo "Updating Sources/App/routes.swift..."
cat << 'EOF' > Sources/App/routes.swift
import Vapor
import Foundation

func routes(_ app: Application) throws {
    app.get("ping") { req async -> String in
        return "pong"
    }

    app.get(":category", ":queryName") { req async throws -> String in
        if let data = "[DEBUG] Route: Request received for \(req.url.path)\n".data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
        let category = req.parameters.get("category") ?? ""
        let queryName = req.parameters.get("queryName") ?? ""
        return try await QueryProcessor.run(req: req, category: category, queryName: queryName)
    }
}
EOF

echo "=== Fix Complete ==="
echo "Starting server..."
swift run Run serve --port 5000
