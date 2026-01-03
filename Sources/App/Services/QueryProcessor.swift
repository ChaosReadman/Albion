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
        
        // 現在のディレクトリ（プロジェクトルート）を取得
        let rootDir = FileManager.default.currentDirectoryPath

        // パス設定
        let baseDir = "\(rootDir)/queryRoot"
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
        
        // コンパイル要否判定 (バイナリがない、またはXQueryが更新されている場合)
        let fileManager = FileManager.default
        let xqyModDate = (try? fileManager.attributesOfItem(atPath: xqyPath)[.modificationDate] as? Date) ?? Date.distantPast
        let binModDate = (try? fileManager.attributesOfItem(atPath: binaryFile)[.modificationDate] as? Date) ?? Date.distantPast
        
        if !fileManager.fileExists(atPath: binaryFile) || xqyModDate > binModDate {
            // Swiftコード生成 (トランスパイル)
            debugLog("QueryProcessor: Transpiling XQuery...")
            let sourceCode = try transpile(xqy: xqyContent, req: req, rootPath: rootDir)
            
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
        } else {
            debugLog("QueryProcessor: Using cached binary.")
        }
        
        // 実行
        debugLog("QueryProcessor: Executing binary...")
        let startTime = Date()
        let run = Process()
        run.executableURL = URL(fileURLWithPath: binaryFile)
        
        // 環境変数としてクエリパラメータを渡す
        var env = ProcessInfo.processInfo.environment
        for (key, value) in req.queryDictionary {
            env[key] = value
        }
        run.environment = env
        
        let pipe = Pipe()
        run.standardOutput = pipe
        try run.run()
        run.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let duration = Date().timeIntervalSince(startTime)
        debugLog("QueryProcessor: Execution finished. Time: \(String(format: "%.4f", duration))s, Output size: \(data.count) bytes")
        return String(data: data, encoding: .utf8) ?? ""
    }
    
    // 簡易XQueryトランスパイラ
    static func transpile(xqy: String, req: Request, rootPath: String) throws -> String {
        debugLog("Transpiling: Start")
        
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
        
        let xmlPath = "\(rootPath)/\(docName)" 
        
        // 3. FLWOR式の抽出
        // FLWOR式全体を特定する (for ... return ... } まで)
        let flworRegex = try NSRegularExpression(pattern: #"(for\s+\$[\s\S]+?return\s+[\s\S]+)\}"#)
        guard let flworMatch = flworRegex.firstMatch(in: xqy, options: [], range: nsRange) else {
             throw Abort(.internalServerError, reason: "No FLWOR expression found")
        }
        
        // コードブロック '{' の開始位置を探す (FLWORの前にあるはず)
        let preFlwor = xqy[..<xqy.index(xqy.startIndex, offsetBy: flworMatch.range.location)]
        guard let codeBlockStart = preFlwor.lastIndex(of: "{") else {
             throw Abort(.internalServerError, reason: "No code block start '{' found")
        }
        
        // Header (XML部分) と Prologue (let ... 等のコード部分) に分離
        let rawHeader = String(preFlwor[..<codeBlockStart])
        let prologue = String(preFlwor[preFlwor.index(after: codeBlockStart)...])
        
        // Headerから宣言(declare)を除去
        let staticHeader = rawHeader.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).starts(with: "declare") }
            .joined(separator: "\n")
        
        // FLWOR本体 (for ... return ...) の取得
        guard let flworBodyRange = Range(flworMatch.range(at: 1), in: xqy) else {
             throw Abort(.internalServerError, reason: "FLWOR body range error")
        }
        let flworBody = String(xqy[flworBodyRange])
        let flworBodyNSRange = NSRange(flworBody.startIndex..<flworBody.endIndex, in: flworBody)
        
        debugLog("Transpiling: Extracting for loop...")
        let forRegex = try NSRegularExpression(pattern: #"for\s+\$([a-zA-Z0-9_]+)\s+in"#)
        guard let forMatch = forRegex.firstMatch(in: flworBody, options: [], range: flworBodyNSRange) else {
             throw Abort(.internalServerError, reason: "No for loop found in XQuery")
        }
        guard let forVarRange = Range(forMatch.range(at: 1), in: flworBody) else {
             throw Abort(.internalServerError, reason: "Regex range error in for loop")
        }
        let loopVar = String(flworBody[forVarRange])

        debugLog("Transpiling: Extracting clauses...")
        let whereRegex = try NSRegularExpression(pattern: #"where\s+([\s\S]+?)\s+order by"#)
        let whereClause = whereRegex.firstMatch(in: flworBody, options: [], range: flworBodyNSRange).flatMap {
            Range($0.range(at: 1), in: flworBody).map { String(flworBody[$0]) }
        } ?? "true"
        
        let orderRegex = try NSRegularExpression(pattern: #"order by\s+([\s\S]+?)\s+return"#)
        let orderClause = orderRegex.firstMatch(in: flworBody, options: [], range: flworBodyNSRange).flatMap {
            Range($0.range(at: 1), in: flworBody).map { String(flworBody[$0]) }
        } ?? ""
        
        let returnRegex = try NSRegularExpression(pattern: #"return\s+([\s\S]+)"#)
        let returnClause = returnRegex.firstMatch(in: flworBody, options: [], range: flworBodyNSRange).flatMap {
            Range($0.range(at: 1), in: flworBody).map { String(flworBody[$0]) }
        } ?? ""
        
        debugLog("Transpiling: Generating Swift code...")
        
        // Helper to convert XQuery expressions to Swift
        func convertCommon(_ expr: String) -> String {
            var s = expr
            // 関数名前空間の除去 (se:hirakata -> hirakata)
            s = s.replacingOccurrences(of: "([a-zA-Z0-9_]+):([a-zA-Z0-9_]+)\\(", with: "$2(", options: .regularExpression)
            // ループ変数のパス変換 ($food/NAME -> val(path, "NAME"))
            s = s.replacingOccurrences(of: "\\$\(loopVar)/([A-Z0-9_-]+)", with: #"val(path, "$1")"#, options: .regularExpression)
            s = s.replacingOccurrences(of: "\\$\(loopVar)/@([A-Z0-9_-]+)", with: #"attr(path, "$1")"#, options: .regularExpression)
            // その他の変数 ($var -> var)
            s = s.replacingOccurrences(of: "\\$([a-zA-Z0-9_]+)", with: "$1", options: .regularExpression)
            return s
        }
        
        func convertLogic(_ expr: String) -> String {
            var s = expr
            s = s.replacingOccurrences(of: "contains(", with: "contains_wrapper(")
            s = s.replacingOccurrences(of: #"\s+or\s+"#, with: " || ", options: .regularExpression)
            s = s.replacingOccurrences(of: #"\s+and\s+"#, with: " && ", options: .regularExpression)
            s = s.replacingOccurrences(of: #"(?<![<>!])=(?!=)"#, with: "==", options: .regularExpression)
            return convertCommon(s)
        }
        
        let swiftWhere = convertLogic(String(whereClause))
        let swiftOrder = convertLogic(String(orderClause))
        
        var swiftReturn = String(returnClause)
        swiftReturn = swiftReturn.replacingOccurrences(of: "{", with: "\\(")
        swiftReturn = swiftReturn.replacingOccurrences(of: "}", with: ")")
        swiftReturn = convertCommon(swiftReturn)
        swiftReturn = swiftReturn.replacingOccurrences(of: "/string\\(\\)", with: "", options: .regularExpression)
        
        // Footerの取得
        let flworEndIndex = xqy.index(xqy.startIndex, offsetBy: flworMatch.range.location + flworMatch.range.length)
        let footer = String(xqy[flworEndIndex...])
        
        // Prologue内の 'let' を変換 (let $var := expr -> let var = expr)
        var swiftPrologue = ""
        let letRegex = try NSRegularExpression(pattern: #"let\s+\$([a-zA-Z0-9_]+)\s*:=\s*(.+)"#)
        let prologueRange = NSRange(prologue.startIndex..<prologue.endIndex, in: prologue)
        
        // 外部変数の定義 (XQuery内で使われているが、letやforで定義されていない変数を環境変数から取得)
        // 簡易的に、req.queryDictionaryにあるキーはすべて環境変数から取得するコードを生成
        var paramDefs = ""
        for (key, _) in req.queryDictionary {
            paramDefs += "let \(key) = getEnv(\"\(key)\")\n"
        }
        
        letRegex.enumerateMatches(in: prologue, options: [], range: prologueRange) { (match, _, _) in
            guard let match = match, let r1 = Range(match.range(at: 1), in: prologue), let r2 = Range(match.range(at: 2), in: prologue) else { return }
            let varName = String(prologue[r1])
            let expr = convertCommon(String(prologue[r2]))
            swiftPrologue += "let \(varName) = \(expr)\n"
        }
        
        // XPathのパスセグメントを抽出 (//FOODS/FOOD -> ["FOODS", "FOOD"])
        let pathSegments = xpathQuery.replacingOccurrences(of: "//", with: "/").split(separator: "/").map { "\"\($0)\"" }.joined(separator: ", ")

        let template = #"""
        import Foundation
        #if canImport(Dispatch)
        import Dispatch
        #endif
        #if canImport(FoundationXML)
        import FoundationXML
        #endif

        func hirakata(_ s: String) -> String {
            return s.unicodeScalars.map { scalar in
                if scalar.value >= 0x3041 && scalar.value <= 0x3096 {
                    return String(UnicodeScalar(scalar.value + 0x60)!)
                }
                return String(scalar)
            }.joined()
        }
        
        // キャッシュクラス (スレッドセーフ)
        class FileCache {
            static let shared = FileCache()
            private var dirCache: [String: [String]] = [:]
            private var fileCache: [String: String] = [:]
            private let lock = NSLock()
            
            func contentsOfDirectory(at path: String) -> [String]? {
                lock.lock()
                if let existing = dirCache[path] {
                    lock.unlock()
                    return existing
                }
                lock.unlock()
                
                guard let items = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
                
                lock.lock()
                dirCache[path] = items
                lock.unlock()
                return items
            }
            
            func contentsOfFile(at path: String) -> String? {
                lock.lock()
                if let existing = fileCache[path] {
                    lock.unlock()
                    return existing
                }
                lock.unlock()
                
                guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
                
                lock.lock()
                fileCache[path] = content
                lock.unlock()
                return content
            }
        }
        
        // ファイルシステムから値を直接読み取るヘルパー
        func val(_ path: String, _ name: String) -> String {
            // path直下の *_name ディレクトリを探す
            guard let items = FileCache.shared.contentsOfDirectory(at: path) else { return "" }
            if let dirName = items.first(where: { $0.hasSuffix("_" + name) }) {
                let innerPath = path + "/" + dirName + "/inner.txt"
                return FileCache.shared.contentsOfFile(at: innerPath) ?? ""
            }
            return ""
        }
        
        func attr(_ path: String, _ name: String) -> String {
            let attrPath = path + "/attr.txt"
            guard let content = FileCache.shared.contentsOfFile(at: attrPath) else { return "" }
            var result = ""
            content.enumerateLines { line, stop in
                let parts = line.split(separator: "=", maxSplits: 1)
                if parts.count == 2 && parts[0] == name {
                    result = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                    stop = true
                }
            }
            return result
        }
        
        func contains_wrapper(_ s1: String, _ s2: String) -> Bool {
            return s1.contains(s2)
        }
        func getEnv(_ name: String) -> String {
            return ProcessInfo.processInfo.environment[name] ?? ""
        }

        \#(paramDefs)
        \#(swiftPrologue)

        let xmlPath = "\#(xmlPath)"
        var resultPaths: [String] = []
        
        // ファイルシステム探索ロジック
        let segments = [\#(pathSegments)]
        
        func searchRecursive(currentPath: String, depth: Int) {
            if depth >= segments.count {
                resultPaths.append(currentPath)
                return
            }
            
            let targetName = segments[depth]
            guard let items = FileCache.shared.contentsOfDirectory(at: currentPath) else { return }
            
            // N_TargetName にマッチするものを探す
            // インデックス順にソートして処理 (コンパイラ負荷軽減のため分割)
            let matchedItems = items.compactMap { name -> (Int, String)? in
                guard name.hasSuffix("_" + targetName) else { return nil }
                let parts = name.split(separator: "_")
                guard let first = parts.first, let idx = Int(first) else { return nil }
                return (idx, name)
            }.sorted { $0.0 < $1.0 }.map { $0.1 }
            
            for item in matchedItems {
                searchRecursive(currentPath: currentPath + "/" + item, depth: depth + 1)
            }
        }
        
        searchRecursive(currentPath: xmlPath, depth: 0)
        
        var filteredPaths: [String] = []
        let filterLock = NSLock()
        
        DispatchQueue.concurrentPerform(iterations: resultPaths.count) { i in
            let path = resultPaths[i]
            if \#(swiftWhere) {
                filterLock.lock()
                filteredPaths.append(path)
                filterLock.unlock()
            }
        }
        
        filteredPaths.sort { 
            let v1 = \#(swiftOrder.replacingOccurrences(of: "element", with: "$0").replacingOccurrences(of: "path", with: "$0"))
            let v2 = \#(swiftOrder.replacingOccurrences(of: "element", with: "$1").replacingOccurrences(of: "path", with: "$1"))
            return v1 < v2
        }
        
        print("""
\#(staticHeader)
""")
        
        for path in filteredPaths {
            print("""
\#(swiftReturn)
""")
        }
        
        print("""
\#(footer)
""")
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
