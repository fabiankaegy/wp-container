import Foundation
import Network

// Repro for Apple `container` published-port forwarder data loss (upstream bug).
//
// The forwarder behind `container run -p 127.0.0.1:<port>:80` discards
// in-flight response data when the guest closes a connection while the
// host-side reader lags. A reader that drains instantly usually wins the race;
// one that pauses ~3ms between reads (any real proxy or busy consumer) loses
// the response tail at a random offset — with a CLEAN EOF, no error.
//
// Usage (against a running WP Container site serving a multi-MB file):
//   swiftc -parse-as-library scripts/repro-forwarder-truncation.swift -o /tmp/repro
//   /tmp/repro 127.0.0.1 <published-port> /wp-includes/js/dist/block-library.js <host-header>  # truncates
//   /tmp/repro <container-ip> 80          /wp-includes/js/dist/block-library.js <host-header>  # never truncates
//
// Expected-vs-actual: both invocations should report the same byte count; the
// published-port path comes up short on most runs. WP Container's own proxy
// works around this by dialing container IPs directly (HTTPSProxy.Route).
@main
struct ReproForwarderTruncation {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 4 else {
            print("usage: repro <host> <port> <path> [hostHeader]")
            exit(2)
        }
        let host = args[1], port = UInt16(args[2])!, path = args[3]
        let hostHeader = args.count > 4 ? args[4] : host
        let queue = DispatchQueue(label: "repro")
        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        var total = 0
        let done = DispatchSemaphore(value: 0)

        func pump() {
            // The 3ms stall between reads is the trigger: it lets the guest
            // finish + close while bytes are still queued host-side.
            usleep(3000)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                total += data?.count ?? 0
                if isComplete || error != nil {
                    print("RECEIVED total=\(total) isComplete=\(isComplete) error=\(error.map { "\($0)" } ?? "nil")")
                    conn.cancel()
                    done.signal()
                    return
                }
                pump()
            }
        }
        conn.stateUpdateHandler = { state in
            if case .ready = state {
                let req = "GET \(path) HTTP/1.1\r\nHost: \(hostHeader)\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(req.utf8), completion: .contentProcessed { _ in pump() })
            }
            if case .failed(let e) = state { print("FAILED \(e)"); done.signal() }
        }
        conn.start(queue: queue)
        _ = done.wait(timeout: .now() + 60)
    }
}
