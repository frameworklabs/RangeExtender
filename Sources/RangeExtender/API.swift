// RangeExtender

import Dispatch

/// A protocol to inform the user of the `RangeExtender` on changes in its state or on values received from the Ranger.
///
/// - Note: All the defined delegate methods are called on the queue provided on construction of the corresponding `RangeExtender`.
public protocol RangeExtenderDelegate : AnyObject {
    
    /// Called when the `state` of the `RangeExtender` changes.
    func rangeExtender(_ rangeExtender: RangeExtender, didChangeState state: RangeExtenderState)
    
    /// Called when a valid `range` value is received for the given `RangeExtender`.
    func rangeExtender(_ rangeExtender: RangeExtender, didReceiveRange range: Int)
    
    /// Called when a valid `battery` value is received for the given `RangeExtender`.
    func rangeExtender(_ rangeExtender: RangeExtender, didReceiveBattery battery: Int)
}

/// Defines the possible mutual exclusive states a `RangeExtender` can be in at a moment.
public enum RangeExtenderState : CaseIterable {
    
    /// State after construction and before `start` is called for the first time.
    case initialized
    
    /// State when `start` is called.
    case starting
    
    /// State when the `RangeExtender` scans for Ranger objects near by.
    ///
    /// There is **no** timeout on the scanning phase. If you want to stop scanning, call `stop` on the `RangeExtender`
    /// and maybe retry some time later.
    case scanning
    
    /// State when a connection is established to the first detected Ranger object.
    ///
    /// When a Ranger object was detected previously, a connection attempt will be made first with it the next time `start` is called
    /// again.
    case connecting
    
    /// State when a connection has been established and data is expected to be received.
    case connected
    
    /// State reached when either `stop` is called explicitly or an error occured after starting.
    case stopped
}

/// An actor to establish a connection with a Ranger device and to receive `range` and `battery` notifications from it.
public final class RangeExtender {

    /// Set your delegate implementation to receive state and value callbacks.
    public weak var delegate: RangeExtenderDelegate?
    
    /// The current state of the `RangeExtender`.
    public var state: RangeExtenderState {
        queue.sync {
            state_
        }
    }
    
    /// The current range value from the Ranger device. Will be `nil` if device is not connected.
    ///
    /// The range value is in mm.
    public var range: Int? {
        queue.sync {
            range_
        }
    }
    
    /// The current battery value from the Ranger device. Will be `nil` if device is not connected.
    ///
    /// The battery value is a state-of-charge value in the range from 0% to 100%.
    public var battery: Int? {
        queue.sync {
            battery_
        }
    }
    
    let queue = DispatchQueue(label: "RangeExtender")
        
    var state_: RangeExtenderState = .initialized {
        didSet {
            if oldValue != state_ {
                if let delegate = delegate  {
                    let state = state_
                    callbackQueue.async {
                        delegate.rangeExtender(self, didChangeState: state)
                    }
                }
            }
        }
    }
    
    var range_: Int? {
        didSet {
            if oldValue != range_ {
                if let delegate = delegate, let range = range_ {
                    callbackQueue.async {
                        delegate.rangeExtender(self, didReceiveRange: range)
                    }
                }
            }
        }
    }
    
    var battery_: Int?{
        didSet {
            if oldValue != battery_ {
                if let delegate = delegate, let battery = battery_ {
                    callbackQueue.async {
                        delegate.rangeExtender(self, didReceiveBattery: battery)
                    }
                }
            }
        }
    }
    
    private let callbackQueue: DispatchQueue
    private var impl: RangeExtenderImpl!

    /// Constructs a new `RangeExtender` actor.
    ///
    /// - Parameter queue: the queue on which the delegate callback methods must be called. If not provided an arbitrary queue is used.
    public init(queue: DispatchQueue = .global()) {
        callbackQueue = queue
        impl = RangeExtenderImpl(rangeExtender: self)
    }

    /// Starts the process to find a Ranger object nearby and to receive notification values from it.
    ///
    /// The `state` property will report the phase of the process. Once a connection has been established
    /// the `range` and `battery` properties will be updated when the Ranger device notifies new values.
    ///
    /// When the `delegate` has been set, callbacks on it will inform you on  state transitions and vallue received
    /// from a connected Ranger device.
    public func start() {
        queue.async { [self] in
            impl.start()
        }
    }

    /// Stops the process triggered by `start`.
    ///
    /// You can stop the process in any `state` - e.g. in the `scanning` state to limit this energy consuming phase.
    public func stop() {
        queue.async { [self] in
            impl.stop()
        }
    }
}
