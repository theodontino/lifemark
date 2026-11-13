import Foundation
let suiteName = "LifeScreenPolicyTests." + UUID().uuidString
let testDefaults = UserDefaults(suiteName: suiteName)!
defer { testDefaults.removePersistentDomain(forName: suiteName) }
enum Preset { case custom }
struct OpenAICompatibleConfiguration {
 let preset: Preset
 let baseURL: String
 let modelID: String
 var isComplete: Bool { !modelID.isEmpty && URL(string: baseURL)?.host != nil }
}
struct OpenAICompatibleRuntimeConfiguration {
 let endpoint: String
 let modelID: String
 let bearerToken: String?
}
enum LifeAIConfiguration {
 static var key = "test-key"
 static var failRead = false
 static func readAPIKey() throws -> String {
  if failRead { throw NSError(domain: "isolated-key-read", code: 1) }
  return key
 }
}
/* POLICY_IMPLEMENTATION */

var failures: [String] = []
var count = 0
func expect(_ ok: @autoclosure () -> Bool, _ name: String) {
 count += 1
 if !ok() { failures.append(name); print("FAIL: " + name) }
 else { print("PASS: " + name) }
}
func set(_ value: Any, _ key: String) { testDefaults.set(value, forKey: key) }
func validSetup() {
 set(true, "life.screen.sessionEnabled"); set(true, "life.ai.enabled")
 set("https://example.test/v1", "life.ai.baseURL"); set("vision-model", "life.ai.model")
 LifeAIConfiguration.key = "test-key"; LifeAIConfiguration.failRead = false
}
let runtime = OpenAICompatibleRuntimeConfiguration(endpoint: "https://example.test/v1", modelID: "vision-model", bearerToken: "test-key")
expect(!LifeScreenAnalysisPolicy.isAllowed(), "empty suite default disabled")
expect(!LifeScreenAnalysisPolicy.requestAllowed(runtime), "default blocks requests")
validSetup()
expect(LifeScreenAnalysisPolicy.isAllowed(), "valid session allowed")
expect(LifeScreenAnalysisPolicy.requestAllowed(runtime), "matching endpoint model key allowed")
set(false, "life.ai.enabled")
expect(!LifeScreenAnalysisPolicy.requestAllowed(runtime), "master AI off blocks")
validSetup(); set(false, "life.screen.sessionEnabled")
expect(!LifeScreenAnalysisPolicy.requestAllowed(runtime), "session off blocks")
validSetup()
for base in ["https://example.test/v1", "http://localhost:11434/v1", "http://127.0.0.1:11434/v1", "http://[::1]:11434/v1"] {
 set(base, "life.ai.baseURL")
 expect(LifeScreenAnalysisPolicy.configuration() != nil, "allow URL " + base)
}
for base in ["http://example.test/v1", "ftp://example.test/v1", "https://user:secret@example.test/v1", "https://user@example.test/v1", "https:///", ""] {
 set(base, "life.ai.baseURL")
 expect(LifeScreenAnalysisPolicy.configuration() == nil, "reject URL " + base)
}
validSetup(); set("  ", "life.ai.model")
expect(!LifeScreenAnalysisPolicy.isAllowed(), "blank model blocks")
validSetup(); set("https://changed.test/v1", "life.ai.baseURL")
expect(!LifeScreenAnalysisPolicy.requestAllowed(runtime), "stale endpoint blocks")
validSetup(); set("changed-model", "life.ai.model")
expect(!LifeScreenAnalysisPolicy.requestAllowed(runtime), "stale model blocks")
validSetup(); LifeAIConfiguration.key = "changed-key"
expect(!LifeScreenAnalysisPolicy.requestAllowed(runtime), "stale API key blocks")
validSetup(); LifeAIConfiguration.failRead = true
expect(!LifeScreenAnalysisPolicy.requestAllowed(runtime), "key read failure blocks")
validSetup(); LifeAIConfiguration.key = " test-key \n"
expect(LifeScreenAnalysisPolicy.requestAllowed(runtime), "current API key trimmed")
validSetup(); LifeAIConfiguration.key = ""
let noKey = OpenAICompatibleRuntimeConfiguration(endpoint: runtime.endpoint, modelID: runtime.modelID, bearerToken: nil)
expect(LifeScreenAnalysisPolicy.requestAllowed(noKey), "empty API key supports local no-auth endpoint")
validSetup(); set("session-a", "life.screen.sessionID")
expect(LifeScreenAnalysisPolicy.requestAllowed(runtime, sessionID: "session-a"), "admitted session allowed")
set(false, "life.screen.sessionEnabled"); set(true, "life.screen.sessionEnabled"); set("session-b", "life.screen.sessionID")
expect(!LifeScreenAnalysisPolicy.requestAllowed(runtime, sessionID: "session-a"), "old session blocked after close and reopen")
expect(LifeScreenAnalysisPolicy.requestAllowed(runtime, sessionID: "session-b"), "new session allowed")
print("Policy assertions: \(count), failures: \(failures.count)")
if !failures.isEmpty { exit(1) }
