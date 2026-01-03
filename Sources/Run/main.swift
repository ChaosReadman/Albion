import App
import Vapor
#if os(Linux)
import Glibc
#else
import Darwin
#endif

setbuf(stdout, nil) // ログのバッファリングを無効化
var env = try Environment.detect()
try LoggingSystem.bootstrap(from: &env)
let app = try await Application.make(env)
defer { app.shutdown() }
try await configure(app)
try await app.execute()