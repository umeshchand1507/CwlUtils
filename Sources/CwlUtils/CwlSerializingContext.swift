//
//  CwlSerializingContext.swift
//  CwlUtils
//
//  Created by Matt Gallagher on 19/1/19.
//  Copyright © 2019 Matt Gallagher ( https://www.cocoawithlove.com ). All rights reserved.
//

import Foundation

/// An `ExecutionContext` wraps a mutex around calls invoked by an underlying execution context. The effect is to serialize concurrent contexts (immediate or concurrent).
public struct SerializingContext: ExecutionContext {
	public let underlying: ExecutionContext
	public let mutex = PThreadMutex(type: .recursive)
	
	public init(concurrentContext: ExecutionContext) {
		underlying = concurrentContext
	}
	
	public var type: ExecutionType {
		switch underlying.type {
		case .immediate: return .mutex
		case .concurrentAsync: return .serialAsync
		default: return underlying.type
		}
	}
	
	/// Run `execute` normally on the execution context
	public func invoke(_ execute: @escaping () -> Void) {
		if case .some(.direct) = underlying as? Exec {
			mutex.sync(execute: execute)
		} else {
			underlying.invoke { [mutex] in mutex.sync(execute: execute) }
		}
	}
	
	/// Run `execute` asynchronously on the execution context
	public func invokeAsync(_ execute: @escaping () -> Void) {
		underlying.invokeAsync { [mutex] in mutex.sync(execute: execute) }
	}
	
	@available(*, deprecated, message: "Use invokeSync instead")
	public func invokeAndWait(_ execute: @escaping () -> Void) {
		_ = invokeSync(execute)
	}
	
	/// Run `execute` on the execution context but don't return from this function until the provided function is complete.
	public func invokeSync<Return>(_ execute: () -> Return) -> Return {
		if case .some(.direct) = underlying as? Exec {
			return mutex.sync(execute: execute)
		} else {
			return underlying.invokeSync { [mutex] in mutex.sync(execute: execute) }
		}
	}
	
	/// Run `execute` on the execution context after `interval` (plus `leeway`) unless the returned `Lifetime` is cancelled or released before running occurs.
	public func singleTimer(interval: DispatchTimeInterval, leeway: DispatchTimeInterval, handler: @escaping () -> Void) -> Lifetime {
		return mutex.sync { () -> Lifetime in
			let wrapper = MutexWrappedLifetime(mutex: mutex)
			let lifetime = underlying.singleTimer(interval: interval, leeway: leeway) { [weak wrapper] in
				if let w = wrapper {
					w.mutex.sync {
						// Need to perform this double check since the timer may have been cancelled/changed before we
						if w.lifetime != nil {
							handler()
						}
					}
				}
			}
			wrapper.lifetime = lifetime
			return wrapper
		}
	}
	
	/// Run `execute` on the execution context after `interval` (plus `leeway`), passing the `parameter` value as an argument, unless the returned `Lifetime` is cancelled or released before running occurs.
	public func singleTimer<T>(parameter: T, interval: DispatchTimeInterval, leeway: DispatchTimeInterval, handler: @escaping (T) -> Void) -> Lifetime {
		return mutex.sync { () -> Lifetime in
			let wrapper = MutexWrappedLifetime(mutex: mutex)
			let lifetime = underlying.singleTimer(parameter: parameter, interval: interval, leeway: leeway) { [weak wrapper] p in
				if let w = wrapper {
					w.mutex.sync {
						if w.lifetime != nil {
							handler(p)
						}
					}
				}
			}
			wrapper.lifetime = lifetime
			return wrapper
		}
	}
	
	/// Run `execute` on the execution context after `interval` (plus `leeway`), and again every `interval` (within a `leeway` margin of error) unless the returned `Lifetime` is cancelled or released before running occurs.
	public func periodicTimer(interval: DispatchTimeInterval, leeway: DispatchTimeInterval, handler: @escaping () -> Void) -> Lifetime {
		return mutex.sync { () -> Lifetime in
			let wrapper = MutexWrappedLifetime(mutex: mutex)
			let lifetime = underlying.periodicTimer(interval: interval, leeway: leeway) { [weak wrapper] in
				if let w = wrapper {
					w.mutex.sync {
						if w.lifetime != nil {
							handler()
						}
					}
				}
			}
			wrapper.lifetime = lifetime
			return wrapper
		}
	}
	
	/// Run `execute` on the execution context after `interval` (plus `leeway`), passing the `parameter` value as an argument, and again every `interval` (within a `leeway` margin of error) unless the returned `Lifetime` is cancelled or released before running occurs.
	public func periodicTimer<T>(parameter: T, interval: DispatchTimeInterval, leeway: DispatchTimeInterval, handler: @escaping (T) -> Void) -> Lifetime {
		return mutex.sync { () -> Lifetime in
			let wrapper = MutexWrappedLifetime(mutex: mutex)
			let lifetime = underlying.periodicTimer(parameter: parameter, interval: interval, leeway: leeway) { [weak wrapper] p in
				if let w = wrapper {
					w.mutex.sync {
						if w.lifetime != nil {
							handler(p)
						}
					}
				}
			}
			wrapper.lifetime = lifetime
			return wrapper
		}
	}
	
	/// Gets a timestamp representing the host uptime the in the current context
	public func timestamp() -> DispatchTime {
		return underlying.timestamp()
	}
}

/// A wrapper around Lifetime that applies a mutex on the cancel operation.
/// This is a class so that `SerializingContext` can pass it weakly to the timer closure, avoiding having the timer keep itself alive.
private class MutexWrappedLifetime: Lifetime {
	var lifetime: Lifetime? = nil
	let mutex: PThreadMutex
	
	init(mutex: PThreadMutex) {
		self.mutex = mutex
	}
	
	func cancel() {
		mutex.sync {
			lifetime?.cancel()
			lifetime = nil
		}
	}
	
	deinit {
		cancel()
	}
}

@available(*, deprecated, message:"Use Exec.queue instead")
public typealias CustomDispatchQueue = DispatchQueueContext

/// Combines a `DispatchQueue` and an `ExecutionType` to create an `ExecutionContext`.
@available(*, deprecated, message:"Use Exec.queue instead")
public struct DispatchQueueContext: ExecutionContext {
	/// The underlying DispatchQueue
	public let queue: DispatchQueue
	
	/// A description about how functions will be invoked on an execution context.
	public let type: ExecutionType
	
	public init(sync: Bool = true, concurrent: Bool = false, qos: DispatchQoS = .default) {
		self.type = sync ? .mutex : (concurrent ? .concurrentAsync : .serialAsync)
		queue = DispatchQueue(label: "", qos: qos, attributes: concurrent ? DispatchQueue.Attributes.concurrent : DispatchQueue.Attributes(), autoreleaseFrequency: .inherit, target: nil)
	}
	
	/// Run `execute` normally on the execution context
	public func invoke(_ execute: @escaping () -> Void) {
		if case .mutex = type {
			queue.sync(execute: execute)
		} else {
			queue.async(execute: execute)
		}
	}
	
	/// Run `execute` asynchronously on the execution context
	public func invokeAsync(_ execute: @escaping () -> Void) {
		queue.async(execute: execute)
	}
	
	@available(*, deprecated, message: "Use invokeSync instead")
	public func invokeAndWait(_ execute: @escaping () -> Void) {
		_ = invokeSync(execute)
	}
	
	/// Run `execute` on the execution context but don't return from this function until the provided function is complete.
	public func invokeSync<Return>(_ execute: () -> Return) -> Return {
		return queue.sync(execute: execute)
	}
	
	/// Run `execute` on the execution context after `interval` (plus `leeway`) unless the returned `Lifetime` is cancelled or released before running occurs.
	public func singleTimer(interval: DispatchTimeInterval, leeway: DispatchTimeInterval, handler: @escaping () -> Void) -> Lifetime {
		return DispatchSource.singleTimer(interval: interval, leeway: leeway, queue: queue, handler: handler) as! DispatchSource
	}
	
	/// Run `execute` on the execution context after `interval` (plus `leeway`), passing the `parameter` value as an argument, unless the returned `Lifetime` is cancelled or released before running occurs.
	public func singleTimer<T>(parameter: T, interval: DispatchTimeInterval, leeway: DispatchTimeInterval, handler: @escaping (T) -> Void) -> Lifetime {
		return DispatchSource.singleTimer(parameter: parameter, interval: interval, leeway: leeway, queue: queue, handler: handler) as! DispatchSource
	}
	
	/// Run `execute` on the execution context after `interval` (plus `leeway`), and again every `interval` (within a `leeway` margin of error) unless the returned `Lifetime` is cancelled or released before running occurs.
	public func periodicTimer(interval: DispatchTimeInterval, leeway: DispatchTimeInterval, handler: @escaping () -> Void) -> Lifetime {
		return DispatchSource.repeatingTimer(interval: interval, leeway: leeway, queue: queue, handler: handler) as! DispatchSource
	}
	
	/// Run `execute` on the execution context after `interval` (plus `leeway`), passing the `parameter` value as an argument, and again every `interval` (within a `leeway` margin of error) unless the returned `Lifetime` is cancelled or released before running occurs.
	public func periodicTimer<T>(parameter: T, interval: DispatchTimeInterval, leeway: DispatchTimeInterval, handler: @escaping (T) -> Void) -> Lifetime {
		return DispatchSource.repeatingTimer(parameter: parameter, interval: interval, leeway: leeway, queue: queue, handler: handler) as! DispatchSource
	}
	
	/// Gets a timestamp representing the host uptime the in the current context
	public func timestamp() -> DispatchTime {
		return DispatchTime.now()
	}
}
