//
//  PromisedReply.swift
//  ios
//
//  Copyright © 2018 Tinode. All rights reserved.
//

import Foundation

enum PromisedReplyError: Error {
    case illegalStateError(String)
    //case decode
}

// Inspired by https://github.com/uber/swift-concurrency/blob/master/Sources/Concurrency/CountDownLatch.swift
private class CountDownLatch {
    private let condition = NSCondition()
    private var conditionCount: Int

    public init(count: Int) {
        assert(count > 0, "CountDownLatch must have an initial count that is greater than 0.")
        conditionCount = count
    }
    public func countDown() {
        guard conditionCount > 0 else {
            return
        }
        condition.lock()
        conditionCount -= 1
        condition.broadcast()
        condition.unlock()
    }
    public func await() {
        guard conditionCount > 0 else {
            return
        }
        condition.lock()
        defer {
            condition.unlock()
        }
        while conditionCount > 0 {
            // We may be woken up by a broadcast in countDown.
            condition.wait()
        }
    }
}

// todo(!!!!): make it thread-safe.
class PromisedReply<Value> {
    typealias SuccessHandler = ((Value) throws -> PromisedReply<Value>?)?
    typealias FailureHandler = ((Error) throws -> PromisedReply<Value>?)?
    enum State {
        case waiting
        case resolved(Value)
        case rejected(Error)
        
        var isDone: Bool {
            get {
                switch self {
                case .resolved, .rejected:
                    return true
                default:
                    return false
                }
            }
        }
    }

    private var state: State = .waiting
    private var successHandler: SuccessHandler
    private var failureHandler: FailureHandler
    private var nextPromise: PromisedReply<Value>?
    private var countDownLatch: CountDownLatch?
    var isResolved: Bool {
        get {
            if case .resolved = state { return true }
            return false
        }
    }
    var isRejected: Bool {
        get {
            if case .rejected = state { return true }
            return false
        }
    }
    var isDone: Bool {
        get {
            return state.isDone
        }
    }
            
    public init() {
        countDownLatch = CountDownLatch(count: 1)
    }
    public init(value: Value) {
        //result = .success(value)
        state = .resolved(value)
        countDownLatch = CountDownLatch(count: 1)
    }
    public init(error: Error) {
        state = .rejected(error)
        countDownLatch = CountDownLatch(count: 1)
    }

    func resolve(result: Value) throws {
        // critical section
        defer {
            countDownLatch?.countDown()
            // down the semaphore
            print("downing the semaphore")
        }
        guard case .waiting = state else {
            throw PromisedReplyError.illegalStateError("Resolve: Promise already resolved.")
        }
        state = .resolved(result)
        try callOnSuccess(result: result)
    }
    
    func reject(error: Error) throws {
        print("rejecting promise \(error)")
        // critical section
        defer {
            // down the semaphore
            countDownLatch?.countDown()
            print("down the semaphore")
        }
        guard case .waiting = state else {
            // down the semaphore
            throw PromisedReplyError.illegalStateError("Promise already resolved/rejected")
        }
        state = .rejected(error)
        try callOnFailure(err: error)
    }
    @discardableResult
    func then(onSuccess successHandler: SuccessHandler,
              onFailure failureHandler: FailureHandler) throws -> PromisedReply<Value>? {
        // start critical section
        guard nextPromise == nil else {
            throw PromisedReplyError.illegalStateError("Multiple calls to then are not supported")
        }
        self.successHandler = successHandler
        self.failureHandler = failureHandler
        self.nextPromise = PromisedReply<Value>()
        do {
            switch state {
            case .resolved(let result):
                try callOnSuccess(result: result)
                break
            case .rejected(let error):
                try callOnFailure(err: error)
                break
            case .waiting: break
            }
        } catch {
            nextPromise = PromisedReply<Value>(error: error)
        }
        return nextPromise
    }
    
    private func callOnSuccess(result: Value) throws {
        var ret: PromisedReply<Value>? = nil
        do {
            if let sh = successHandler {
                ret = try sh(result)
            }
        } catch {
            // faiure handler
            try handleFailure(e: error)
            return
        }
        try handleSuccess(ret: ret)
    }
    
    private func callOnFailure(err: Error) throws {
        if let fh = failureHandler {
            // Try to recover.
            do {
                try handleSuccess(ret: fh(err))
            } catch {
                try handleFailure(e: error)
            }
        } else {
            // Pass to the next handler.
            try handleFailure(e: err)
        }
    }
    
    private func handleSuccess(ret: PromisedReply<Value>?) throws {
        guard let np = nextPromise else {
            if let r = ret, case .rejected(let retError) = r.state {
                throw retError
            }
            return
        }
        guard let r = ret else {
            guard case let .resolved(value) = state else {
                throw PromisedReplyError.illegalStateError("called handleSuccess on a non-resolved promise")
            }
            try np.resolve(result: value)
            return
        }
        switch r.state {
        case .resolved(let value):
            try np.resolve(result: value)
            break
        case .rejected(let error):
            try np.reject(error: error)
            break
        case .waiting:
            r.insertNextPromise(next: np)
            break
        }
    }

    private func handleFailure(e: Error) throws {
        if let np = nextPromise {
            try np.reject(error: e)
        } else {
            throw e
        }
    }

    private func insertNextPromise(next: PromisedReply<Value>) {
        // critical section
        if let np = nextPromise {
            next.insertNextPromise(next: np)
        }
        nextPromise = next
    }

    func getResult() throws -> Value {
        countDownLatch?.await()
        switch state {
        case .resolved(let value):
            return value
        case .rejected(let e):
            throw e
        case .waiting:
            throw PromisedReplyError.illegalStateError("Called getResult on unresolved promise")
        }
    }
    @discardableResult
    func waitResult() throws -> Bool {
        countDownLatch?.await()
        return isResolved
    }
}
