# RangeExtender

This little Swift Package helps to connect to a [Ranger device](https://github.com/frameworklabs/ranger) and receive range and battery state-of-charge values from it.

## Usage

RangeExtender hides the Bluetooth communication and state-handling logic behind a simple Swift API. To receive values from a Ranger device, follow these steps:

1. Add this Package into your project.
2. Declare `import RangeExtender`.
3. Create a class which adopts the `RangeExtenderDelegate` and implements its callback methods.
4. Create an instance of `RangeExtender` and assign your delegate to it.
5. Call `start()` on the `RangeExtender`.
6. Observe state and value changes delivered via the delegate.
7. Call `stop()` to cancel a connection (or connection attempt) to a Ranger device.

A simple usage might thus look like this:
```swift
import RangeExtender

class MyRangeExtenderDelegate : RangeExtenderDelegate {
    func rangeExtender(_ rangeExtender: RangeExtender, didChangeState state: RangeExtenderState) {
        print("state: \(state)")
    }
    func rangeExtender(_ rangeExtender: RangeExtender, didReceiveRange range: Int) {
        print("range: \(range)mm")
    }
    func rangeExtender(_ rangeExtender: RangeExtender, didReceiveBattery battery: Int) {
        print("battery: \(battery)%")
    }
}

let rangeExtender = RangeExtender()
let myRangeExtenderDelegate = MyRangeExtenderDelegate()
rangeExtender.delegate = myRangeExtenderDelegate

rangeExtender.start()
```

## Notes

Connecting to a Bluetooth device is a bit tedious as it consists of different phases triggered by various events.
Normally, an implementation uses a State-Machine to handle this logic. Here, we use the State-Flow by Control-Flow approach instead which allows to express the logic as a structured synchronous program. This is done with the help of the [Pappe Project](https://github.com/frameworklabs/Pappe). 
