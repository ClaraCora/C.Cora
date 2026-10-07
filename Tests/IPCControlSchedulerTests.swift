import Foundation

private func expect(_ condition: Bool, _ message: String) {
    precondition(condition, message)
}

private func waitFor(_ semaphore: DispatchSemaphore, _ message: String) {
    expect(semaphore.wait(timeout: .now() + 3) == .success, message)
}

private func waitUntilIdle(_ scheduler: IPCControlScheduler) {
    let deadline = Date().addingTimeInterval(3)
    while scheduler.stats().inFlight != 0 && Date() < deadline {
        Thread.sleep(forTimeInterval: 0.005)
    }
    expect(scheduler.stats().inFlight == 0, "workers did not drain")
}

@main
struct IPCControlSchedulerTests {
    static func main() {
        capacityAndSessionCancellation()
        saturatedHeavyWorkDoesNotBlockLightQueries()
        providerSingleFlight()
        perScriptConcurrency()
        queuedTimeout()
        print("IPC control scheduler tests passed")
    }

    static func capacityAndSessionCancellation() {
        let scheduler = IPCControlScheduler()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let cancelled = DispatchSemaphore(value: 0)
        let rejected = DispatchSemaphore(value: 0)
        for workClass in [IPCControlScheduler.WorkClass.light, .light, .light, .light,
                          .snapshot, .snapshot, .snapshot, .heavy] {
            expect(scheduler.submit(workClass, operation: {
                started.signal()
                waitFor(release, "active worker stalled")
            }, onReject: { preconditionFailure("active capacity rejected") }), "worker rejected")
        }
        for _ in 0..<8 { waitFor(started, "eight workers did not start") }
        for _ in 0..<24 {
            expect(scheduler.submit(.heavy, operation: {
                preconditionFailure("cancelled pending work executed")
            }, onReject: { preconditionFailure("queue capacity rejected") },
               onCancel: { cancelled.signal() }), "pending worker rejected")
        }
        expect(!scheduler.submit(.heavy, operation: {}, onReject: { rejected.signal() }),
               "queue overflow accepted")
        waitFor(rejected, "overflow did not reply")
        expect(scheduler.stats().inFlight == 8 && scheduler.stats().queueDepth == 24,
               "scheduler bounds changed")
        scheduler.cancelPending()
        for _ in 0..<24 { waitFor(cancelled, "old session pending work retained") }
        for _ in 0..<8 { release.signal() }
        waitUntilIdle(scheduler)
        let stats = scheduler.stats()
        expect(stats.peakInFlight == 8 && stats.peakQueueDepth == 24
               && stats.rejected == 1 && stats.cancelled == 32 && stats.queueDepth == 0,
               "capacity/cancellation accounting wrong")
    }

    static func saturatedHeavyWorkDoesNotBlockLightQueries() {
        let scheduler = IPCControlScheduler()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let lightDone = DispatchSemaphore(value: 0)
        for _ in 0..<2 {
            scheduler.submit(.heavy, operation: {
                started.signal(); waitFor(release, "heavy worker stalled")
            }, onReject: { preconditionFailure("heavy capacity rejected") })
        }
        for _ in 0..<2 { waitFor(started, "heavy workers did not start") }
        scheduler.submit(.heavy, operation: {}, onReject: { preconditionFailure("pending work rejected") })
        scheduler.submit(.light, operation: { lightDone.signal() },
                         onReject: { preconditionFailure("light query rejected") })
        waitFor(lightDone, "heavy saturation blocked light query")
        release.signal(); release.signal()
        waitUntilIdle(scheduler)
    }

    static func providerSingleFlight() {
        let scheduler = IPCControlScheduler()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        scheduler.submit(.heavy, key: "ruleProviders:node:a#1", operation: {
            started.signal(); waitFor(release, "provider worker stalled")
        }, onReject: { preconditionFailure("provider rejected") })
        waitFor(started, "provider did not start")
        for key in ["ruleProviders:node:a#1", "ruleProviders:all#1"] {
            expect(!scheduler.submit(.heavy, key: key, operation: {}, onReject: {}),
                   "overlapping provider refresh accepted")
        }
        // A new session's same-name Provider must not inherit the old key.
        let newDone = DispatchSemaphore(value: 0)
        scheduler.submit(.heavy, key: "ruleProviders:node:a#2", operation: { newDone.signal() },
                         onReject: { preconditionFailure("new session provider blocked") })
        waitFor(newDone, "new provider did not execute")
        release.signal()
        waitUntilIdle(scheduler)
        scheduler.submit(.heavy, key: "proxyProviders:all#2", operation: {
            started.signal(); waitFor(release, "all-provider worker stalled")
        }, onReject: { preconditionFailure("all-provider refresh rejected") })
        waitFor(started, "all-provider worker did not start")
        expect(!scheduler.submit(.heavy, key: "proxyProviders:node:b#2", operation: {}, onReject: {}),
               "single provider overlapped all-provider refresh")
        release.signal()
        waitUntilIdle(scheduler)
    }

    static func perScriptConcurrency() {
        let scheduler = IPCControlScheduler()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let queuedDone = DispatchSemaphore(value: 0)
        for id in ["script-a", "script-b"] {
            for _ in 0..<4 {
                scheduler.submit(.script, scriptID: id, operation: {
                    started.signal(); waitFor(release, "script worker stalled")
                }, onReject: { preconditionFailure("script concurrency reduced") })
            }
        }
        for _ in 0..<8 { waitFor(started, "two scripts did not execute eight requests") }
        scheduler.submit(.script, scriptID: "script-a", operation: { queuedDone.signal() },
                         onReject: { preconditionFailure("fifth script request rejected") })
        expect(scheduler.stats().queueDepth == 1, "single script exceeded four requests")
        for _ in 0..<8 { release.signal() }
        waitFor(queuedDone, "queued script request did not resume")
        waitUntilIdle(scheduler)
        expect(scheduler.stats().completedByClass["script"] == 9,
               "script completion statistics lost")
    }

    static func queuedTimeout() {
        let scheduler = IPCControlScheduler(maximumQueueWait: 0.05)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let timeout = DispatchSemaphore(value: 0)
        for _ in 0..<2 {
            scheduler.submit(.heavy, operation: {
                started.signal(); waitFor(release, "timeout blocker stalled")
            }, onReject: { preconditionFailure("timeout blocker rejected") })
        }
        for _ in 0..<2 { waitFor(started, "timeout blockers did not start") }
        scheduler.submit(.heavy, operation: { preconditionFailure("expired work executed") },
                         onReject: { preconditionFailure("timeout queue rejected") },
                         onTimeout: { timeout.signal() })
        waitFor(timeout, "queued task did not time out")
        expect(scheduler.stats().timedOut == 1 && scheduler.stats().queueDepth == 0,
               "timeout accounting wrong")
        release.signal(); release.signal()
        waitUntilIdle(scheduler)
    }
}
