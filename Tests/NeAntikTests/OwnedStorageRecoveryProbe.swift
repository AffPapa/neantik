import Foundation

/// Test-only CDP adapter. Both HTTP origin and DevTools must be literal loopback.
enum OwnedStorageRecoveryProbe {
    static func check(portFile: URL, origin: URL, write: Bool) async throws -> Bool {
        guard origin.scheme == "http", origin.host == "127.0.0.1",
              origin.port != nil, origin.path == "/", origin.user == nil,
              origin.password == nil, origin.query == nil, origin.fragment == nil
        else { throw CocoaError(.validationMissingMandatoryProperty) }
        let raw = try String(contentsOf: portFile, encoding: .utf8)
        guard let first = raw.split(separator: "\n").first,
              let port = UInt16(first), port > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, _) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/json/list")!)
        guard let pages = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let page = pages.first(where: { $0["type"] as? String == "page" }),
              let rawSocket = page["webSocketDebuggerUrl"] as? String,
              let url = URL(string: rawSocket), url.scheme == "ws",
              url.host == "127.0.0.1", url.port == Int(port)
        else { throw CocoaError(.fileReadCorruptFile) }
        var request = URLRequest(url: url)
        request.setValue("http://neantik.local", forHTTPHeaderField: "Origin")
        let socket = session.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let timeout = Task {
            try await Task.sleep(nanoseconds: 15_000_000_000)
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer { timeout.cancel() }
        let encodedOrigin = String(data: try JSONEncoder().encode(origin.absoluteString), encoding: .utf8)!
        let expression = """
        (async()=>{
          if(location.href!==\(encodedOrigin)) return {ready:false};
          const db=await new Promise((ok,no)=>{
            const r=indexedDB.open('owned-recovery',1);
            r.onupgradeneeded=()=>r.result.createObjectStore('values');
            r.onsuccess=()=>ok(r.result);r.onerror=()=>no(r.error);
          });
          try {
            if(\(write ? "true" : "false")) {
              localStorage.setItem('owned-recovery','synthetic-A');
              await new Promise((ok,no)=>{
                const tx=db.transaction('values','readwrite',{durability:'strict'});
                tx.objectStore('values').put('synthetic-A','key');
                tx.oncomplete=ok;tx.onerror=()=>no(tx.error);tx.onabort=()=>no(tx.error);
              });
            }
            const value=await new Promise((ok,no)=>{
              const r=db.transaction('values').objectStore('values').get('key');
              r.onsuccess=()=>ok(r.result);r.onerror=()=>no(r.error);
            });
            return {ready:true,indexed:value==='synthetic-A',local:localStorage.getItem('owned-recovery')==='synthetic-A'};
          } finally {db.close();}
        })()
        """
        let command: [String: Any] = ["id":1,"method":"Runtime.evaluate","params":[
            "expression":expression,"awaitPromise":true,"returnByValue":true]]
        let payload = try JSONSerialization.data(withJSONObject: command)
        try await socket.send(.string(String(decoding: payload, as: UTF8.self)))
        while true {
            let message = try await socket.receive()
            let bytes: Data
            switch message {
            case .string(let text): bytes = Data(text.utf8)
            case .data(let data): bytes = data
            @unknown default: continue
            }
            guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String:Any],
                  object["id"] as? Int == 1 else { continue }
            guard object["error"] == nil,
                  let result = object["result"] as? [String:Any],
                  result["exceptionDetails"] == nil,
                  let value = result["result"] as? [String:Any]
            else { throw CocoaError(.coderInvalidValue) }
            guard let checks = value["value"] as? [String:Bool] else {
                throw CocoaError(.coderInvalidValue)
            }
            print("Owned storage probe: ready=\(checks["ready"] == true) indexed=\(checks["indexed"] == true) local=\(checks["local"] == true)")
            if checks["ready"] != true { return false }
            guard checks["indexed"] == true, checks["local"] == true else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return true
        }
    }
}
