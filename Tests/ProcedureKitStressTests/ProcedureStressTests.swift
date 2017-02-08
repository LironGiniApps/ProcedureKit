//
//  ProcedureKit
//
//  Copyright © 2016 ProcedureKit. All rights reserved.
//

import XCTest
import TestingProcedureKit
@testable import ProcedureKit
import Dispatch

class ProcedureCompletionBlockStressTest: StressTestCase {

    func test__completion_blocks() {

        stress { batch, iteration in
            batch.dispatchGroup.enter()
            let procedure = TestProcedure(name: "Batch \(batch.number), Iteration \(iteration)")
            procedure.addCompletionBlock { batch.dispatchGroup.leave() }
            batch.queue.add(operation: procedure)
        }
    }
}

class CancelProcedureWithErrorsStressTest: StressTestCase {

    func test__cancel_or_finish_with_errors() {

        // NOTE: It is possible for a TestProcedure below to finish prior to being cancelled

        stress { batch, iteration in
            batch.dispatchGroup.enter()
            let procedure = TestProcedure(name: "Batch \(batch.number), Iteration \(iteration)")
            procedure.addDidFinishBlockObserver { _, _ in
                batch.dispatchGroup.leave()
            }
            batch.queue.add(operation: procedure)
            procedure.cancel(withError: TestError())
        }
    }

    func test__cancel_with_errors_prior_to_execute() {

        stress { batch, iteration in
            batch.dispatchGroup.enter()
            let procedure = TestProcedure(name: "Batch \(batch.number), Iteration \(iteration)")
            procedure.addDidFinishBlockObserver { _, errors in
                if errors.isEmpty {
                    DispatchQueue.main.async {
                        XCTAssertFalse(errors.isEmpty, "errors is empty - cancel errors were not propagated")
                        batch.dispatchGroup.leave()
                    }
                }
                else {
                    batch.dispatchGroup.leave()
                }
            }
            procedure.cancel(withError: TestError())
            batch.queue.add(operation: procedure)
        }
    }

    func test__cancel_with_errors_from_will_execute_observer() {

        stress { batch, iteration in
            batch.dispatchGroup.enter()
            let procedure = TestProcedure(name: "Batch \(batch.number), Iteration \(iteration)")
            procedure.addDidFinishBlockObserver { _, errors in
                if errors.isEmpty {
                    DispatchQueue.main.async {
                        XCTAssertFalse(errors.isEmpty, "errors is empty - cancel errors were not propagated")
                        batch.dispatchGroup.leave()
                    }
                }
                else {
                    batch.dispatchGroup.leave()
                }
            }
            procedure.addWillExecuteBlockObserver { (procedure, _) in
                procedure.cancel(withError: TestError())
            }
            batch.queue.add(operation: procedure)
        }
    }
}

class ProcedureConditionStressTest: StressTestCase {

    func test__adding_many_conditions() {

        StressLevel.custom(1, 10_000).forEach { _, _ in
            procedure.add(condition: TrueCondition())
        }
        wait(for: procedure, withTimeout: 10)
        XCTAssertProcedureFinishedWithoutErrors()
    }

    func test__adding_many_conditions_each_with_single_dependency() {

        StressLevel.custom(1, 10_000).forEach { _, _ in
            procedure.add(condition: TestCondition(producedDependencies: [TestProcedure()]) { .success(true) })
        }
        wait(for: procedure, withTimeout: 10)
        XCTAssertProcedureFinishedWithoutErrors()
    }
}

class ProcedureConditionsWillFinishObserverCancelThreadSafety: StressTestCase {

    func test__conditions_do_not_fail_when_will_finish_observer_cancels_and_deallocates_procedure() {
        // NOTES:
        //      Previously, this test would fail in Condition.execute(),
        //      where if `Condition.operation` was nil the following assertion would trigger:
        //          assertionFailure("Condition executed before operation set.")
        //      However, this was not an accurate assert in all cases.
        //
        //      In this test case, all conditions have their .procedure properly set as a result of
        //      `queue.addOperation(operation)`.
        //
        //      Calling `procedure.cancel()` results in the procedure deiniting prior to the access of the weak
        //      `Condition.procedure` var, which was then nil (when accessed).
        //
        //      After removing this assert, the following additional race condition was triggered:
        //      "attempted to retain deallocated object" (EXC_BREAKPOINT)
        //      in the Procedure.EvaluateConditions's WillFinishObserver
        //      Associated Report: https://github.com/ProcedureKit/ProcedureKit/issues/416
        //
        //      This was caused by a race condition between the procedure deiniting and the
        //      EvaluateConditions's WillFinishObserver accessing `unowned self`,
        //      which is easily triggerable by the following test case.
        //
        //      This test should now pass without error.

        stress { batch, iteration in
            batch.dispatchGroup.enter()
            let procedure = TestProcedure()
            procedure.add(condition: FalseCondition())
            procedure.addDidFinishBlockObserver { _, _ in
                batch.dispatchGroup.leave()
            }
            batch.queue.add(operation: procedure)
            procedure.cancel()
        }
    }
}

class ProcedureFinishStressTest: StressTestCase {

    class TestAttemptsMultipleFinishesProcedure: Procedure {
        public init(name: String = "Test Procedure") {
            super.init()
            self.name = name
        }
        override func execute() {
            DispatchQueue.global().async() {
                self.finish()
            }
            DispatchQueue.global().async() {
                self.finish()
            }
            DispatchQueue.global().async() {
                self.finish()
            }
        }
    }

    func test__concurrent_calls_to_finish_only_first_succeeds() {
        // NOTES:
        //      This test should pass without any "cyclic state transition: finishing -> finishing" errors.

        stress { batch, iteration in
            batch.dispatchGroup.enter()
            let procedure = TestAttemptsMultipleFinishesProcedure()
            var didFinish = false
            let lock = NSLock()
            procedure.addDidFinishBlockObserver { _, _ in
                let finishedMoreThanOnce = lock.withCriticalScope(block: { () -> Bool in
                    guard !didFinish else {
                        // procedure finishing more than once
                        return true
                    }
                    didFinish = true
                    return false
                })
                guard !finishedMoreThanOnce else {
                    batch.incrementCounter(named: "finishedProcedureMoreThanOnce")
                    return
                }
                // add small delay before leaving to increase the odds that concurrent finishes are caught
                let deadline = DispatchTime(uptimeNanoseconds: UInt64(0.1 * Double(NSEC_PER_SEC)))
                DispatchQueue.global().asyncAfter(deadline: deadline) {
                    batch.dispatchGroup.leave()
                }
            }
            batch.queue.add(operation: procedure)
        }
    }

    override func ended(batch: BatchProtocol) {
        XCTAssertEqual(batch.counter(named: "finishedProcedureMoreThanOnce"), 0)
        super.ended(batch: batch)
    }
}

class ProcedureCancellationHandlerConcurrencyTest: StressTestCase {

    func test__cancelled_procedure_no_concurrent_events() {

        stress(level: StressLevel.custom(2, 1000)) { batch, iteration in
            batch.dispatchGroup.enter()
            let procedure = EventConcurrencyTrackingProcedure(execute: { procedure in
                usleep(50000)
                procedure.finish()
            })
            procedure.addDidFinishBlockObserver(block: { (procedure, error) in
                DispatchQueue.main.async {
                    self.XCTAssertProcedureNoConcurrentEvents(procedure)
                    batch.dispatchGroup.leave()
                }
            })
            batch.queue.add(operation: procedure)
            procedure.cancel()
        }
    }
}

class ProcedureFinishHandlerConcurrencyTest: StressTestCase {

    func test__finish_from_asynchronous_callback_while_execute_is_still_running() {
        // NOTE: Do not use this test as an example of what to do.

        stress(level: StressLevel.custom(2, 1000)) { batch, iteration in
            batch.dispatchGroup.enter()
            let procedure = EventConcurrencyTrackingProcedure(execute: { procedure in
                assert(!DispatchQueue.isMainDispatchQueue)
                let semaphore = DispatchSemaphore(value: 0)
                // dispatch finish on another thread...
                DispatchQueue.global().async { [unowned procedure] in
                    procedure.finish()
                    semaphore.signal()
                }
                // and block this thread until the call to finish() returns
                semaphore.wait()
            })
            procedure.addDidFinishBlockObserver(block: { (procedure, error) in
                DispatchQueue.main.async {
                    self.XCTAssertProcedureNoConcurrentEvents(procedure)
                    batch.dispatchGroup.leave()
                }
            })
            batch.queue.add(operation: procedure)
            procedure.cancel()
        }
    }
}