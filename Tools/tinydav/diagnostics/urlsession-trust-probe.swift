// URLSession trust probe: reproduces the app's WebDAV transport challenge
// handling — accept any server certificate on the server-trust challenge,
// then answer the HTTP basic-auth challenge with fixture credentials — and
// fetches a fixture file with it. CI runs this on the runner (macOS shares
// the Foundation/CFNetwork stack with the simulator) so that a regression in
// server-trust override handling surfaces in this step instead of as a
// silent zero-download sync inside a test.
//
// Usage: swift urlsession-trust-probe.swift <url> <user> <password>
// Exits 0 when the request completes with a 2xx status, 1 otherwise.

import Foundation

let args = CommandLine.arguments
guard args.count == 4, let url = URL(string: args[1]) else {
    FileHandle.standardError.write("usage: urlsession-trust-probe <url> <user> <password>\n".data(using: .utf8)!)
    exit(2)
}

final class ProbeDelegate: NSObject, URLSessionDataDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.serverTrust != nil {
            print("probe: server-trust challenge (previousFailureCount=\(challenge.previousFailureCount)) — accepting any certificate")
            completionHandler(.useCredential, URLCredential(trust: challenge.protectionSpace.serverTrust!))
        } else {
            print("probe: \(challenge.protectionSpace.authenticationMethod) challenge — answering with fixture credentials")
            completionHandler(.useCredential, URLCredential(user: args[2], password: args[3], persistence: .forSession))
        }
    }
}

let semaphore = DispatchSemaphore(value: 0)
let session = URLSession(configuration: .default, delegate: ProbeDelegate(), delegateQueue: nil)
let task = session.dataTask(with: url) { data, response, error in
    if let error = error {
        print("probe: FAILED — \(error)")
        exit(1)
    }
    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
    print("probe: request completed — HTTP \(statusCode), \(data?.count ?? 0) bytes")
    exit((200..<300).contains(statusCode) ? 0 : 1)
}
task.resume()
semaphore.wait()
