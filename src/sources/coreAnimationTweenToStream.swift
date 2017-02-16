/*
 Copyright 2016-present The Material Motion Authors. All Rights Reserved.

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

import Foundation
import IndefiniteObservable

/** Create a core animation tween system for a Tween plan. */
public func coreAnimation<T>(_ tween: Tween<T>) -> MotionObservable<T> {
  return MotionObservable { observer in

    var animationKeys: [String] = []
    var subscriptions: [Subscription] = []
    var activeAnimations = Set<String>()

    var emit = { (animation: CAPropertyAnimation) in
      guard let duration = tween.duration.read() else {
        return
      }
      animation.beginTime = tween.delay
      animation.duration = CFTimeInterval(duration)

      let key = NSUUID().uuidString
      activeAnimations.insert(key)
      animationKeys.append(key)

      tween.state.value = .active

      if let timeline = tween.timeline {
        observer.coreAnimation(.timeline(timeline))
      }
      observer.coreAnimation(.add(animation, key, initialVelocity: nil, completionBlock: {
        activeAnimations.remove(key)
        if activeAnimations.count == 0 {
          tween.state.value = .atRest
        }
      }))
      animationKeys.append(key)
    }

    var checkAndEmit = {
      switch tween.mode {
      case .values(let values):
        let animation: CAPropertyAnimation
        let timingFunctions = tween.timingFunctions
        if values.count > 1 {
          let keyframeAnimation = CAKeyframeAnimation()
          keyframeAnimation.values = values
          keyframeAnimation.keyTimes = tween.keyPositions?.map { NSNumber(value: $0) }
          keyframeAnimation.timingFunctions = timingFunctions
          animation = keyframeAnimation
        } else {
          let basicAnimation = CABasicAnimation()
          basicAnimation.toValue = values.last
          basicAnimation.timingFunction = timingFunctions.first
          animation = basicAnimation
        }
        observer.next(values.last!)

        emit(animation)

      case .path(let path):
        subscriptions.append(path.subscribe(next: { pathValue in
          let keyframeAnimation = CAKeyframeAnimation()
          keyframeAnimation.path = pathValue
          keyframeAnimation.timingFunctions = tween.timingFunctions

          if let mode = tween.mode as? TweenMode<CGPoint> {
            observer.next(pathValue.getAllPoints().last! as! T)
          } else {
            assertionFailure("Unsupported type \(type(of: T.self))")
          }

          emit(keyframeAnimation)

        }, coreAnimation: { _ in }))
      }
    }

    let activeSubscription = tween.enabled.dedupe().subscribe(next: { enabled in
      if enabled {
        checkAndEmit()
      } else {
        animationKeys.forEach { observer.coreAnimation(.remove($0)) }
        activeAnimations.removeAll()
        animationKeys.removeAll()
        tween.state.value = .atRest
      }
    }, coreAnimation: { _ in })

    return {
      animationKeys.forEach { observer.coreAnimation(.remove($0)) }
      subscriptions.forEach { $0.unsubscribe() }
      activeSubscription.unsubscribe()
    }
  }
}

extension CGPath {

  // Iterates over each registered point in the CGPath. We must use @convention notation to bridge
  // between the swift and objective-c block APIs.
  // Source: http://stackoverflow.com/questions/12992462/how-to-get-the-cgpoints-of-a-cgpath#36374209
  private func forEach(body: @convention(block) (CGPathElement) -> Void) {
    typealias Body = @convention(block) (CGPathElement) -> Void
    let callback: @convention(c) (UnsafeMutableRawPointer, UnsafePointer<CGPathElement>) -> Void = { (info, element) in
      let body = unsafeBitCast(info, to: Body.self)
      body(element.pointee)
    }
    let unsafeBody = unsafeBitCast(body, to: UnsafeMutableRawPointer.self)
    self.apply(info: unsafeBody, function: unsafeBitCast(callback, to: CGPathApplierFunction.self))
  }

  fileprivate func getAllPoints() -> [CGPoint] {
    var arrayPoints: [CGPoint] = []
    self.forEach { element in
      switch (element.type) {
      case .moveToPoint:
        arrayPoints.append(element.points[0])
      case .addLineToPoint:
        arrayPoints.append(element.points[0])
      case .addQuadCurveToPoint:
        arrayPoints.append(element.points[0])
        arrayPoints.append(element.points[1])
      case .addCurveToPoint:
        arrayPoints.append(element.points[0])
        arrayPoints.append(element.points[1])
        arrayPoints.append(element.points[2])
      default: break
      }
    }
    return arrayPoints
  }
}
