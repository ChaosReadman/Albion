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
