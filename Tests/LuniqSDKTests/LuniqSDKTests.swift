import XCTest
@testable import LuniqSDK

// MARK: - Shared helpers

private func queueFileURL() -> URL {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return dir.appendingPathComponent("Luniq").appendingPathComponent("queue.json")
}

private func wipePersistedQueue() {
    try? FileManager.default.removeItem(at: queueFileURL())
}

private func makeConfig(endpoint: String = "http://127.0.0.1:65535",
                        flushIntervalSec: TimeInterval = 3600) -> LuniqConfig {
    LuniqConfig(
        apiKey: "test-key",
        endpoint: endpoint,
        environment: "TEST",
        autoCapture: false,
        enabled: true,
        batchSize: 50,
        flushIntervalSec: flushIntervalSec,
        maxQueueSize: 10_000,
        redactPII: false
    )
}

// MARK: - URLProtocol mock

final class MockURLProtocol: URLProtocol {
    struct Captured {
        let url: URL
        let method: String
        let headers: [String: String]
        let body: Data
    }

    static var captured: [Captured] = []
    static var responder: (URLRequest) -> (Int, Data) = { _ in (200, Data("{}".utf8)) }

    static func reset() {
        captured.removeAll()
        responder = { _ in (200, Data("{}".utf8)) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody
            ?? (request.httpBodyStream.flatMap { Self.drain($0) })
            ?? Data()
        let headers = (request.allHTTPHeaderFields ?? [:])
        MockURLProtocol.captured.append(.init(
            url: request.url!,
            method: request.httpMethod ?? "GET",
            headers: headers,
            body: body
        ))
        let (code, data) = MockURLProtocol.responder(request)
        let resp = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var out = Data()
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buf.deallocate() }
        while stream.hasBytesAvailable {
            let n = stream.read(buf, maxLength: 4096)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return out
    }
}

// MARK: - EventQueue

final class EventQueueTests: XCTestCase {
    override func setUp() { super.setUp(); wipePersistedQueue() }
    override func tearDown() { wipePersistedQueue(); super.tearDown() }

    private func makeEvent(_ name: String) -> Event {
        Event(name: name, properties: ["k": "v"], timestamp: Date(),
              sessionId: "sess", visitorId: "vis", accountId: nil)
    }

    func testEnqueueDequeueIsFIFO() {
        let q = EventQueue()
        (1...5).forEach { q.enqueue(makeEvent("e\($0)")) }
        let batch = q.dequeueBatch(max: 10)
        XCTAssertEqual(batch.map(\.name), ["e1","e2","e3","e4","e5"])
    }

    func testDequeueRespectsMaxAndLeavesRemainder() {
        let q = EventQueue()
        (1...10).forEach { q.enqueue(makeEvent("e\($0)")) }
        XCTAssertEqual(q.dequeueBatch(max: 3).map(\.name), ["e1","e2","e3"])
        XCTAssertEqual(q.dequeueBatch(max: 3).map(\.name), ["e4","e5","e6"])
    }

    func testRequeueRestoresFrontOfQueue() {
        let q = EventQueue()
        (1...3).forEach { q.enqueue(makeEvent("e\($0)")) }
        let batch = q.dequeueBatch(max: 2)
        q.requeue(batch)
        XCTAssertEqual(q.dequeueBatch(max: 10).map(\.name), ["e1","e2","e3"])
    }

    func testLoadRehydratesFromDisk() {
        let q1 = EventQueue()
        q1.enqueue(makeEvent("persisted"))
        let q2 = EventQueue()
        q2.load()
        XCTAssertEqual(q2.dequeueBatch(max: 1).map(\.name), ["persisted"])
    }
}

// MARK: - Identity

final class IdentityManagerTests: XCTestCase {
    func testHashDeterministic() {
        let a = IdentityManager.hashIdentifier("user-123")
        let b = IdentityManager.hashIdentifier("user-123")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 64)
    }

    func testHashDiffersPerInput() {
        let a = IdentityManager.hashIdentifier("user-001")
        let b = IdentityManager.hashIdentifier("user-002")
        XCTAssertNotEqual(a, b)
    }

    func testHashPepperChangesOutput() {
        let a = IdentityManager.hashIdentifier("user-123", pepper: "pulse-v1")
        let b = IdentityManager.hashIdentifier("user-123", pepper: "pulse-v2")
        XCTAssertNotEqual(a, b)
    }

    func testSetPersistsVisitorAndTraits() {
        let m = IdentityManager()
        m.set(visitorId: "v-123", accountId: "a-9", traits: ["plan": "pro"])
        let m2 = IdentityManager()
        XCTAssertEqual(m2.visitorId, "v-123")
        XCTAssertEqual(m2.accountId, "a-9")
        XCTAssertEqual(m2.traits["plan"] as? String, "pro")
    }
}

// MARK: - Event / AnyCodable serialization

final class EventSerializationTests: XCTestCase {
    func testRoundTripPreservesMandatoryParams() throws {
        let props: [String: Any] = [
            "user_id": "u-1",
            "vin_connected": true,
            "vin_vehicle_count": 2,
            "engine_type": "BEV",
            "user_type": "owner",
            "screen_name": "home"
        ]
        let e = Event(name: "$screen", properties: props, timestamp: Date(timeIntervalSince1970: 1_713_312_000),
                      sessionId: "s", visitorId: "v", accountId: nil)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(e)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["name"] as? String, "$screen")
        XCTAssertEqual(json["sessionId"] as? String, "s")
        let p = try XCTUnwrap(json["properties"] as? [String: Any])
        XCTAssertEqual(p["user_id"] as? String, "u-1")
        XCTAssertEqual(p["vin_connected"] as? Bool, true)
        XCTAssertEqual(p["vin_vehicle_count"] as? Int, 2)
        XCTAssertEqual(p["screen_name"] as? String, "home")
    }

    func testNullAndNestedValuesSurvive() throws {
        let props: [String: Any] = [
            "nested": ["a": 1, "b": "x"],
            "list": [1, 2, 3]
        ]
        let e = Event(name: "x", properties: props, timestamp: Date(),
                      sessionId: "s", visitorId: nil, accountId: nil)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(e)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        _ = try dec.decode(Event.self, from: data)
    }
}

// MARK: - Transport (URLProtocol mock)

final class TransportTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        HTTPTransport.extraProtocolClasses = [MockURLProtocol.self]
    }
    override func tearDown() {
        HTTPTransport.extraProtocolClasses = []
        super.tearDown()
    }

    func testTransportPostsToV1EventsWithApiKeyHeader() {
        let cfg = makeConfig(endpoint: "https://mock.test")
        let t = HTTPTransport(config: cfg)
        let event = Event(name: "first_launch", properties: ["brand": "H"], timestamp: Date(),
                          sessionId: "s", visitorId: "v", accountId: nil)
        let exp = expectation(description: "send completes")
        t.send(events: [event]) { ok in
            XCTAssertTrue(ok)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)

        let captured = MockURLProtocol.captured
        XCTAssertEqual(captured.count, 1, "transport should issue exactly one request")
        let req = captured[0]
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.url.path, "/v1/events")
        XCTAssertEqual(req.headers["X-Luniq-Key"], "test-key")
        XCTAssertEqual(req.headers["Content-Type"], "application/json")

        let body = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any]
        let events = body?["events"] as? [[String: Any]]
        XCTAssertEqual(events?.count, 1)
        XCTAssertEqual(events?.first?["name"] as? String, "first_launch")
    }

    func testTransportReportsFailureOn500() {
        MockURLProtocol.responder = { _ in (500, Data()) }
        let t = HTTPTransport(config: makeConfig(endpoint: "https://mock.test"))
        let event = Event(name: "x", properties: [:], timestamp: Date(),
                          sessionId: "s", visitorId: nil, accountId: nil)
        let exp = expectation(description: "send completes")
        t.send(events: [event]) { ok in
            XCTAssertFalse(ok, "non-2xx must surface as failure so batch is requeued")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
    }
}

// MARK: - End-to-end (track → flush → backend receives)

final class EndToEndTests: XCTestCase {
    override func setUp() {
        super.setUp()
        wipePersistedQueue()
        MockURLProtocol.reset()
        HTTPTransport.extraProtocolClasses = [MockURLProtocol.self]
    }
    override func tearDown() {
        HTTPTransport.extraProtocolClasses = []
        wipePersistedQueue()
        super.tearDown()
    }

    func testTrackThenFlushDeliversBatchWithEnrichedFields() {
        let cfg = makeConfig(endpoint: "https://mock.test")
        Luniq.shared.start(config: cfg)
        Luniq.shared.identify(visitorId: "vis-1", accountId: "acc-1",
                               traits: ["engine_type": "BEV", "user_type": "owner"])
        Luniq.shared.track("feature_used", properties: ["feature": "remote_start"])
        Luniq.shared.flush()

        let exp = expectation(description: "ingest observed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if MockURLProtocol.captured.contains(where: { $0.url.path == "/v1/events" }) { exp.fulfill() }
        }
        wait(for: [exp], timeout: 5)

        // SDK init may fan out to /v1/sdk/guides etc.; filter for the events POST.
        let req = MockURLProtocol.captured.first(where: { $0.url.path == "/v1/events" })
        XCTAssertNotNil(req, "events POST must be issued after flush()")
        // Walk every captured /v1/events POST so we don't depend on which
        // batch contains "feature_used" (the SDK can split or coalesce).
        let eventsPosts = MockURLProtocol.captured.filter { $0.url.path == "/v1/events" }
        let allEvents: [[String: Any]] = eventsPosts.compactMap {
            (try? JSONSerialization.jsonObject(with: $0.body)) as? [String: Any]
        }.compactMap { $0["events"] as? [[String: Any]] }.flatMap { $0 }
        guard let evt = allEvents.first(where: { ($0["name"] as? String) == "feature_used" }) else {
            XCTFail("no feature_used event was sent"); return
        }
        XCTAssertEqual(evt["visitorId"] as? String, "vis-1")
        let props = evt["properties"] as? [String: Any]
        XCTAssertEqual(props?["feature"] as? String, "remote_start")
        XCTAssertEqual(props?["os_type"] as? String, "IOS")
        XCTAssertEqual(props?["env"] as? String, "TEST")
        XCTAssertEqual(props?["engine_type"] as? String, "BEV")
    }

    func testOptOutSuppressesEvents() {
        let cfg = makeConfig(endpoint: "https://mock.test")
        Luniq.shared.start(config: cfg)
        Luniq.shared.optOut(true)
        Luniq.shared.track("should_not_fire_X9F")  // unique sentinel name
        Luniq.shared.flush()

        let exp = expectation(description: "no events request issued")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { exp.fulfill() }
        wait(for: [exp], timeout: 3)
        // The singleton may flush residue from prior tests on /v1/events; we only
        // care that THIS test's event name never appears on the wire.
        let allEvents: [[String: Any]] = MockURLProtocol.captured
            .filter { $0.url.path == "/v1/events" }
            .compactMap { (try? JSONSerialization.jsonObject(with: $0.body)) as? [String: Any] }
            .compactMap { $0["events"] as? [[String: Any]] }.flatMap { $0 }
        XCTAssertFalse(
            allEvents.contains(where: { ($0["name"] as? String) == "should_not_fire_X9F" }),
            "opt-out must drop events at track() before they reach the queue"
        )
    }

    func testFailedDeliveryRequeuesForRetry() {
        MockURLProtocol.responder = { _ in (500, Data()) }
        let cfg = makeConfig(endpoint: "https://mock.test")
        Luniq.shared.start(config: cfg)
        Luniq.shared.track("retryable_event")
        Luniq.shared.flush()

        let exp = expectation(description: "first send attempted")
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if MockURLProtocol.captured.contains(where: { $0.url.path == "/v1/events" }) { exp.fulfill() }
        }
        wait(for: [exp], timeout: 5)
        XCTAssertTrue(MockURLProtocol.captured.contains(where: { $0.url.path == "/v1/events" }),
                      "failed events POST should still have been attempted")

        let q = EventQueue(); q.load()
        let remaining = q.dequeueBatch(max: 10)
        XCTAssertTrue(remaining.contains { $0.name == "retryable_event" },
                      "failed batch must be requeued for next flush")
    }
}
