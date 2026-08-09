import XCTest

/// Exercises the cross-process lock primitive that keeps a shared MariaDB
/// container from being retired out from under a start running in another
/// process.
///
/// `flock(2)` is associated with the open file DESCRIPTION, not the process, so
/// two `FileLock`s taken in this one test process contend exactly the way two
/// `wp-container` processes do — the whole protocol is testable without a single
/// container.
final class DatabaseLifecycleLockTests: XCTestCase {

    private var directory: URL!
    private var lockURL: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("wpc-lock-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        lockURL = directory.appendingPathComponent("db-test.lock")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Compatibility matrix

    func testSharedLocksCoexist() throws {
        let a = try XCTUnwrap(FileLock.tryAcquire(at: lockURL, mode: .shared))
        let b = try XCTUnwrap(FileLock.tryAcquire(at: lockURL, mode: .shared))
        let c = try XCTUnwrap(FileLock.tryAcquire(at: lockURL, mode: .shared))
        a.release(); b.release(); c.release()
    }

    /// The dependant side (a start) locks out the retirement side (a stop).
    func testSharedBlocksExclusive() throws {
        let dependent = try XCTUnwrap(FileLock.tryAcquire(at: lockURL, mode: .shared))
        XCTAssertNil(FileLock.tryAcquire(at: lockURL, mode: .exclusive),
                     "a retirement must not be able to start while a lease is held")
        dependent.release()
        let retirement = try XCTUnwrap(FileLock.tryAcquire(at: lockURL, mode: .exclusive),
                                       "releasing the lease must let the retirement through")
        retirement.release()
    }

    /// And the retirement side locks out new dependants for its duration.
    func testExclusiveBlocksEverything() throws {
        let retirement = try XCTUnwrap(FileLock.tryAcquire(at: lockURL, mode: .exclusive))
        XCTAssertNil(FileLock.tryAcquire(at: lockURL, mode: .shared))
        XCTAssertNil(FileLock.tryAcquire(at: lockURL, mode: .exclusive))
        retirement.release()
        let after = try XCTUnwrap(FileLock.tryAcquire(at: lockURL, mode: .shared))
        after.release()
    }

    // MARK: - Release semantics

    /// `release()` is called explicitly at the earliest safe point AND from a
    /// `defer` backstop on every caller, so double release must be harmless.
    func testReleaseIsIdempotent() throws {
        let lock = try XCTUnwrap(FileLock.tryAcquire(at: lockURL, mode: .exclusive))
        lock.release()
        lock.release()
        lock.release()
        let other = try XCTUnwrap(FileLock.tryAcquire(at: lockURL, mode: .exclusive),
                                  "a repeated release must not have closed somebody else's descriptor")
        other.release()
    }

    /// Dropping the last reference releases the lock — the same mechanism the
    /// kernel uses when a process dies, which is why no stale-lock recovery
    /// exists anywhere in this code.
    func testDeallocationReleasesTheLock() throws {
        var lock: FileLock? = FileLock.tryAcquire(at: lockURL, mode: .exclusive)
        XCTAssertNotNil(lock)
        lock = nil
        let after = try XCTUnwrap(FileLock.tryAcquire(at: lockURL, mode: .exclusive))
        after.release()
    }

    // MARK: - Bounded waiting

    /// A wait must never be unbounded: the retirement side gives up and leaves
    /// the container running rather than hanging the idle sweep forever.
    func testBoundedAcquireGivesUp() async throws {
        let dependent = try XCTUnwrap(FileLock.tryAcquire(at: lockURL, mode: .shared))
        defer { dependent.release() }
        let started = ContinuousClock.now
        let result = await FileLock.acquire(at: lockURL, mode: .exclusive,
                                            timeout: .milliseconds(300),
                                            pollInterval: .milliseconds(20))
        let elapsed = ContinuousClock.now - started
        XCTAssertNil(result)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(250))
        XCTAssertLessThan(elapsed, .seconds(5))
    }

    /// The waiting side must actually get the lock once the holder lets go —
    /// this is the "a start waits for the retirement, then boots a fresh
    /// server" half of the protocol.
    func testBoundedAcquireSucceedsAfterTheHolderReleases() async throws {
        let holder = try XCTUnwrap(FileLock.tryAcquire(at: lockURL, mode: .exclusive))
        let url = lockURL!
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            holder.release()
        }
        let waiter = await FileLock.acquire(at: url, mode: .shared,
                                            timeout: .seconds(5),
                                            pollInterval: .milliseconds(20))
        XCTAssertNotNil(waiter)
        waiter?.release()
    }

    /// An uncontended acquire must not pay the poll interval.
    func testUncontendedAcquireIsImmediate() async throws {
        let started = ContinuousClock.now
        let lock = await FileLock.acquire(at: lockURL, mode: .exclusive, timeout: .seconds(5))
        XCTAssertNotNil(lock)
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(500))
        lock?.release()
    }

    /// A missing parent directory is created rather than treated as a failure —
    /// the first lock may well predate anything else writing to Application
    /// Support.
    func testCreatesTheContainingDirectory() throws {
        let nested = directory
            .appendingPathComponent("does", isDirectory: true)
            .appendingPathComponent("not-exist", isDirectory: true)
            .appendingPathComponent("db-test.lock")
        let lock = try XCTUnwrap(FileLock.tryAcquire(at: nested, mode: .exclusive))
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
        lock.release()
    }

    // MARK: - Lock file naming

    /// One lock file per DB CONTAINER: two sites must never serialise against
    /// each other, or one site's start would block another's idle retirement.
    func testDistinctContainersGetDistinctLockFiles() {
        let a = DatabaseLifecycleLock.url(forContainer: "wpc-alpha-db")
        let b = DatabaseLifecycleLock.url(forContainer: "wpc-beta-db")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a, DatabaseLifecycleLock.url(forContainer: "wpc-alpha-db"))
        XCTAssertEqual(a.lastPathComponent, "db-wpc-alpha-db.lock")
        XCTAssertEqual(a.deletingLastPathComponent().lastPathComponent, "WPContainer")
    }

    /// A container name never reaches this from user input, but a lock file is
    /// not worth a path traversal.
    func testLockFileNameIsSanitised() {
        let url = DatabaseLifecycleLock.url(forContainer: "../../etc/passwd")
        XCTAssertEqual(url.lastPathComponent, "db-..-..-etc-passwd.lock")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "WPContainer")
    }
}
