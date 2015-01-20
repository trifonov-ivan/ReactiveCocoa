/// A push-driven stream that sends Events over time, parameterized by the type
/// of values being sent (`T`) and the type of error that can occur (`E`). If no
/// errors should be possible, NoError can be specified for `E`.
///
/// An observer of a Signal will see the exact same sequence of events as all
/// other observers. In other words, events will be sent to all observers at the
/// same time.
///
/// Signals are generally used to represent event streams that are already “in
/// progress,” like notifications, user input, etc. To represent streams that
/// must first be _started_, see the SignalProducer type.
///
/// Signals do not need to be retained. A Signal will be automatically kept
/// alive until the event stream has terminated, or until the operation which
/// yielded the Signal (e.g., SignalProducer.start) has been cancelled.
public final class Signal<T, E: ErrorType> {
	public typealias Observer = SinkOf<Event<T, E>>

	private let lock = NSRecursiveLock()
	private var observers: Bag<Observer>? = Bag()
	private let disposable = CompositeDisposable()

	/// Initializes a Signal that will immediately invoke the given generator,
	/// then forward events sent to the given observer.
	///
	/// The Signal will remain alive until an `Error` or `Completed` event is
	/// sent, or until the signal's `disposable` has been disposed, at which
	/// point the disposable returned from the closure will be disposed as well.
	public init(_ generator: Observer -> Disposable?) {
		lock.name = "org.reactivecocoa.ReactiveCocoa.Signal"

		let sink = Observer { event in
			self.lock.lock()

			if let observers = self.observers {
				for sink in observers {
					sink.put(event)
				}

				if event.isTerminating {
					self.disposable.dispose()
				}
			}

			self.lock.unlock()
		}

		disposable.addDisposable {
			self.lock.lock()
			self.observers = nil
			self.lock.unlock()
		}

		if let d = generator(sink) {
			disposable.addDisposable(d)
		}
	}

	/// A Signal that never sends any events.
	public class var never: Signal {
		return self { _ in nil }
	}

	/// Creates a Signal that will be controlled by sending events to the given
	/// observer (sink).
	///
	/// The Signal will remain alive until an `Error` or `Completed` event is
	/// sent to the observer.
	public class func pipe() -> (Signal, Observer) {
		var sink: Observer!
		let signal = self { innerSink in
			sink = innerSink
			return nil
		}

		return (signal, sink)
	}

	/// Creates a Signal that will be controlled by sending events to the given
	/// observer, and which can be disposed using the returned disposable.
	///
	/// The Signal will remain alive until an `Error` or `Completed` event is
	/// sent to the observer, or until the disposable is used.
	internal class func disposablePipe() -> (Signal, Observer, CompositeDisposable) {
		let (signal, observer) = pipe()
		return (signal, observer, signal.disposable)
	}

	/// Observes the Signal by sending any future events to the given sink. If
	/// the Signal has already terminated, the sink will not receive any events.
	///
	/// Returns a Disposable which can be used to disconnect the sink. Disposing
	/// of the Disposable will have no effect on the Signal itself.
	public func observe<S: SinkType where S.Element == Event<T, E>>(observer: S) -> Disposable {
		let sink = Observer(observer)

		lock.lock()
		let token = self.observers?.insert(sink)
		lock.unlock()

		return ActionDisposable {
			if let token = token {
				self.lock.lock()
				self.observers?.removeValueForToken(token)
				self.lock.unlock()
			}
		}
	}

	/// Observes the Signal by invoking the given callbacks when events are
	/// received. If the Signal has already terminated, none of the specified
	/// callbacks will be invoked.
	///
	/// Returns a Disposable which can be used to stop the invocation of the
	/// callbacks. Disposing of the Disposable will have no effect on the Signal
	/// itself.
	public func observe(next: T -> () = doNothing, error: E -> () = doNothing, completed: () -> () = doNothing) -> Disposable {
		return observe(Event.sink(next: next, error: error, completed: completed))
	}
}

infix operator |> {
	associativity left

	// Bind tighter than assignment, but looser than everything else.
	precedence 95
}

/// Applies a Signal operator to a Signal.
///
/// Example:
///
/// 	intSignal
/// 	|> filter { num in num % 2 == 0 }
/// 	|> map(toString)
/// 	|> observe(next: { string in println(string) })
public func |> <T, E, X>(signal: Signal<T, E>, transform: Signal<T, E> -> X) -> X {
	return transform(signal)
}

/// Maps each value in the signal to a new value.
public func map<T, U, E>(transform: T -> U)(signal: Signal<T, E>) -> Signal<U, E> {
	return Signal { observer in
		return signal.observe(Signal.Observer { event in
			observer.put(event.map(transform))
		})
	}
}

/// Preserves only the values of the signal that pass the given predicate.
public func filter<T, E>(predicate: T -> Bool)(signal: Signal<T, E>) -> Signal<T, E> {
	return Signal { observer in
		return signal.observe(next: { value in
			if predicate(value) {
				sendNext(observer, value)
			}
		}, error: { error in
			sendError(observer, error)
		}, completed: {
			sendCompleted(observer)
		})
	}
}

/// Returns a signal that will yield the first `count` values from the
/// input signal.
public func take<T, E>(count: Int)(signal: Signal<T, E>) -> Signal<T, E> {
	precondition(count >= 0)

	return Signal { observer in
		var taken = 0

		return signal.observe(next: { value in
			if taken < count {
				taken++
				sendNext(observer, value)
			} else {
				sendCompleted(observer)
			}
		}, error: { error in
			sendError(observer, error)
		}, completed: {
			sendCompleted(observer)
		})
	}
}

/// Forwards all events onto the given scheduler, instead of whichever
/// scheduler they originally arrived upon.
public func observeOn<T, E>(scheduler: SchedulerType)(signal: Signal<T, E>) -> Signal<T, E> {
	return Signal { observer in
		return signal.observe(SinkOf { event in
			scheduler.schedule {
				observer.put(event)
			}

			return
		})
	}
}

private class CombineLatestState<T> {
	var latestValue: T?
	var completed = false
}

private func observeWithStates<T, U, E>(signalState: CombineLatestState<T>, otherState: CombineLatestState<U>, lock: NSRecursiveLock, onBothNext: () -> (), onError: E -> (), onBothCompleted: () -> ())(signal: Signal<T, E>) -> Disposable {
	return signal.observe(next: { value in
		lock.lock()

		signalState.latestValue = value
		if otherState.latestValue != nil {
			onBothNext()
		}

		lock.unlock()
	}, error: onError, completed: {
		lock.lock()

		signalState.completed = true
		if otherState.completed {
			onBothCompleted()
		}

		lock.unlock()
	})
}

/// Combines the latest value of the receiver with the latest value from
/// the given signal.
///
/// The returned signal will not send a value until both inputs have sent
/// at least one value each.
public func combineLatestWith<T, U, E>(otherSignal: Signal<U, E>)(signal: Signal<T, E>) -> Signal<(T, U), E> {
	return Signal { observer in
		let lock = NSRecursiveLock()
		lock.name = "org.reactivecocoa.ReactiveCocoa.combineLatestWith"

		let signalState = CombineLatestState<T>()
		let otherState = CombineLatestState<U>()

		let onBothNext = { () -> () in
			let combined = (signalState.latestValue!, otherState.latestValue!)
			sendNext(observer, combined)
		}

		let onError = { sendError(observer, $0) }
		let onBothCompleted = { sendCompleted(observer) }

		let signalDisposable = signal |> observeWithStates(signalState, otherState, lock, onBothNext, onError, onBothCompleted)
		let otherDisposable = otherSignal |> observeWithStates(otherState, signalState, lock, onBothNext, onError, onBothCompleted)

		return CompositeDisposable([ signalDisposable, otherDisposable ])
	}
}

/// Delays `Next` and `Completed` events by the given interval, forwarding
/// them on the given scheduler.
///
/// `Error` events are always scheduled immediately.
public func delay<T, E>(interval: NSTimeInterval, onScheduler scheduler: DateSchedulerType)(signal: Signal<T, E>) -> Signal<T, E> {
	precondition(interval >= 0)

	return Signal { observer in
		return signal.observe(SinkOf { event in
			switch event {
			case .Error:
				scheduler.schedule {
					observer.put(event)
				}

			default:
				let date = scheduler.currentDate.dateByAddingTimeInterval(interval)
				scheduler.scheduleAfter(date) {
					observer.put(event)
				}
			}
		})
	}
}

/// Returns a signal that will skip the first `count` values, then forward
/// everything afterward.
public func skip<T, E>(count: Int)(signal: Signal<T, E>) -> Signal<T, E> {
	precondition(count >= 0)

	if (count == 0) {
		return signal
	}

	return Signal { observer in
		var skipped = 0

		return signal.observe(next: { value in
			if skipped >= count {
				sendNext(observer, value)
			} else {
				skipped++
			}
		}, error: { error in
			sendError(observer, error)
		}, completed: {
			sendCompleted(observer)
		})
	}
}

/// Treats all Events from the input signal as plain values, allowing them to be
/// manipulated just like any other value.
///
/// In other words, this brings Events “into the monad.”
public func materialize<T, E>(signal: Signal<T, E>) -> Signal<Event<T, E>, NoError> {
	return Signal { observer in
		return signal.observe(SinkOf { event in
			sendNext(observer, event)

			if event.isTerminating {
				sendCompleted(observer)
			}
		})
	}
}

/// The inverse of materialize(), this will translate a signal of `Event`
/// _values_ into a signal of those events themselves.
public func dematerialize<T, E>(signal: Signal<Event<T, E>, NoError>) -> Signal<T, E> {
	return Signal { observer in
		return signal.observe(next: { event in
			observer.put(event)
		}, completed: {
			sendCompleted(observer)
		})
	}
}

private struct SampleState<T> {
	var latestValue: T? = nil
	var signalCompleted: Bool = false
	var samplerCompleted: Bool = false
}

/// Forwards the latest value from `signal` whenever `sampler` sends a Next
/// event.
///
/// If `sampler` fires before a value has been observed on `signal`, nothing
/// happens.
///
/// Returns a signal that will send values from `signal`, sampled (possibly
/// multiple times) by `sampler`, then complete once both input signals have
/// completed.
public func sampleOn<T, E>(sampler: Signal<(), NoError>)(signal: Signal<T, E>) -> Signal<T, E> {
	return Signal { observer in
		let state = Atomic(SampleState<T>())

		let signalDisposable = signal.observe(next: { value in
			state.modify { (var st) in
				st.latestValue = value
				return st
			}

			return
		}, error: { error in
			sendError(observer, error)
		}, completed: {
			let oldState = state.modify { (var st) in
				st.signalCompleted = true
				return st
			}

			if oldState.samplerCompleted {
				sendCompleted(observer)
			}
		})

		let samplerDisposable = sampler.observe(next: { _ in
			if let value = state.value.latestValue {
				sendNext(observer, value)
			}
		}, completed: {
			let oldState = state.modify { (var st) in
				st.samplerCompleted = true
				return st
			}

			if oldState.signalCompleted {
				sendCompleted(observer)
			}
		})

		return CompositeDisposable([ signalDisposable, samplerDisposable ])
	}
}

/// Forwards events from `signal` until `trigger` sends a Next or Completed
/// event, at which point the returned signal will complete.
public func takeUntil<T, E>(trigger: Signal<(), NoError>)(signal: Signal<T, E>) -> Signal<T, E> {
	return Signal { observer in
		let signalDisposable = signal.observe(observer)
		let triggerDisposable = trigger.observe(SinkOf { event in
			switch event {
			case .Next, .Completed:
				sendCompleted(observer)

			case .Error:
				break
			}
		})

		return CompositeDisposable([ signalDisposable, triggerDisposable ])
	}
}

/// Forwards events from `signal` with history: values of the returned signal
/// are a tuple whose first member is the previous value and whose second member
/// is the current value. `initial` is supplied as the first member when `signal`
/// sends its first value.
public func combinePrevious<T, E>(initial: T)(signal: Signal<T, E>) -> Signal<(T, T), E> {
	return Signal { observer in
		let previousValueState = Atomic<T?>(nil)
		return signal.observe(next: { value in
			previousValueState.modify { previousValue in
				if let previousValue = previousValue {
					sendNext(observer, (previousValue, value))
				} else {
					sendNext(observer, (initial, value))
				}
				return value
			}
			return
		}, error: { error in
			sendError(observer, error)
		}, completed: {
			sendCompleted(observer)
		})
	}
}

/*
TODO

public func reduce<T, U>(initial: U, combine: (U, T) -> U)(signal: Signal<T>) -> Signal<U>
public func scan<T, U>(initial: U, combine: (U, T) -> U)(signal: Signal<T>) -> Signal<U>
public func skipRepeats<T: Equatable>(signal: Signal<T>) -> Signal<T>
public func skipRepeats<T>(isRepeat: (T, T) -> Bool)(signal: Signal<T>) -> Signal<T>
public func skipWhile<T>(predicate: T -> Bool)(signal: Signal<T>) -> Signal<T>
public func takeLast<T>(count: Int)(signal: Signal<T>) -> Signal<T>
public func takeUntilReplacement<T>(replacement: Signal<T>)(signal: Signal<T>) -> Signal<T>
public func takeWhile<T>(predicate: T -> Bool)(signal: Signal<T>) -> Signal<T>
public func throttle<T>(interval: NSTimeInterval, onScheduler scheduler: DateSchedulerType)(signal: Signal<T>) -> Signal<T>
public func timeoutWithError<T, E>(error: E, afterInterval interval: NSTimeInterval, onScheduler scheduler: DateSchedulerType)(signal: Signal<T, E>) -> Signal<T, E>
public func try<T, E>(operation: T -> Result<(), E>)(signal: Signal<T, E>) -> Signal<T, E>
public func tryMap<T, U, E>(operation: T -> Result<U, E>)(signal: Signal<T, E>) -> Signal<U, E>
public func zipWith<T, U>(otherSignal: Signal<U>)(signal: Signal<T>) -> Signal<(T, U)>
*/

/// Signal.observe() as a free function, for easier use with |>.
public func observe<T, E, S: SinkType where S.Element == Event<T, E>>(sink: S)(signal: Signal<T, E>) -> Disposable {
	return signal.observe(sink)
}

/// Signal.observe() as a free function, for easier use with |>.
public func observe<T, E>(next: T -> () = doNothing, error: E -> () = doNothing, completed: () -> () = doNothing)(signal: Signal<T, E>) -> Disposable {
	return signal.observe(next: next, error: error, completed: completed)
}
