// Copyright 2016 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:quiver/testing/async.dart';
import 'package:quiver/time.dart';
import 'package:test/test.dart' as test_package;
import 'package:vector_math/vector_math_64.dart';

import 'test_async_utils.dart';
import 'stack_manipulation.dart';

/// Enumeration of possible phases to reach in
/// [WidgetTester.pumpWidget] and [TestWidgetsFlutterBinding.pump].
// TODO(ianh): Merge with identical code in the rendering test code.
enum EnginePhase {
  layout,
  compositingBits,
  paint,
  composite,
  flushSemantics,
  sendSemanticsTree
}

const Size _kTestViewportSize = const Size(800.0, 600.0);

/// Base class for bindings used by widgets library tests.
///
/// The [ensureInitialized] method creates (if necessary) and returns
/// an instance of the appropriate subclass.
///
/// When using these bindings, certain features are disabled. For
/// example, [timeDilation] is reset to 1.0 on initialization.
abstract class TestWidgetsFlutterBinding extends BindingBase
  with SchedulerBinding,
       GestureBinding,
       ServicesBinding,
       RendererBinding,
       WidgetsBinding {
  /// Creates and initializes the binding. This function is
  /// idempotent; calling it a second time will just return the
  /// previously-created instance.
  ///
  /// This function will use [AutomatedTestWidgetsFlutterBinding] if
  /// the test was run using `flutter test`, and
  /// [LiveTestWidgetsFlutterBinding] otherwise (e.g. if it was run
  /// using `flutter run`). (This is determined by looking at the
  /// environment variables for a variable called `FLUTTER_TEST`.)
  static WidgetsBinding ensureInitialized() {
    if (WidgetsBinding.instance == null) {
      if (Platform.environment.containsKey('FLUTTER_TEST')) {
        new AutomatedTestWidgetsFlutterBinding._();
      } else {
        new LiveTestWidgetsFlutterBinding._();
      }
    }
    assert(WidgetsBinding.instance is TestWidgetsFlutterBinding);
    return WidgetsBinding.instance;
  }

  @override
  void initInstances() {
    timeDilation = 1.0; // just in case the developer has artificially changed it for development
    super.initInstances();
  }

  bool get inTest;

  /// The default test timeout for tests when using this binding.
  test_package.Timeout get defaultTestTimeout;

  /// Triggers a frame sequence (build/layout/paint/etc),
  /// then flushes microtasks.
  ///
  /// If duration is set, then advances the clock by that much first.
  /// Doing this flushes microtasks.
  ///
  /// The supplied EnginePhase is the final phase reached during the pump pass;
  /// if not supplied, the whole pass is executed.
  Future<Null> pump([ Duration duration, EnginePhase newPhase = EnginePhase.sendSemanticsTree ]);

  /// Artificially calls dispatchLocaleChanged on the Widget binding,
  /// then flushes microtasks.
  Future<Null> setLocale(String languageCode, String countryCode) {
    return TestAsyncUtils.guard(() async {
      assert(inTest);
      Locale locale = new Locale(languageCode, countryCode);
      dispatchLocaleChanged(locale);
      return null;
    });
  }

  /// Acts as if the application went idle.
  ///
  /// Runs all remaining microtasks, including those scheduled as a result of
  /// running them, until there are no more microtasks scheduled.
  ///
  /// Does not run timers. May result in an infinite loop or run out of memory
  /// if microtasks continue to recursively schedule new microtasks.
  Future<Null> idle() {
    TestAsyncUtils.guardSync();
    return new Future<Null>.value();
  }

  /// Returns the exception most recently caught by the Flutter framework.
  ///
  /// Call this if you expect an exception during a test. If an exception is
  /// thrown and this is not called, then the exception is rethrown when
  /// the [testWidgets] call completes.
  ///
  /// If two exceptions are thrown in a row without the first one being
  /// acknowledged with a call to this method, then when the second exception is
  /// thrown, they are both dumped to the console and then the second is
  /// rethrown from the exception handler. This will likely result in the
  /// framework entering a highly unstable state and everything collapsing.
  ///
  /// It's safe to call this when there's no pending exception; it will return
  /// null in that case.
  dynamic takeException() {
    assert(inTest);
    dynamic result = _pendingExceptionDetails?.exception;
    _pendingExceptionDetails = null;
    return result;
  }
  FlutterExceptionHandler _oldExceptionHandler;
  FlutterErrorDetails _pendingExceptionDetails;

  static final Widget _kPreTestMessage = new Center(
    child: new Text(
      'Test starting...',
      style: const TextStyle(color: const Color(0xFFFF0000))
    )
  );

  static final Widget _kPostTestMessage = new Center(
    child: new Text(
      'Test finished.',
      style: const TextStyle(color: const Color(0xFFFF0000))
    )
  );

  /// Whether to include the output of debugDumpApp() when reporting
  /// test failures.
  bool showAppDumpInErrors = false;

  /// Invoke the callback inside a [FakeAsync] scope on which [pump] can
  /// advance time.
  ///
  /// Returns a future which completes when the test has run.
  ///
  /// Called by the [testWidgets] and [benchmarkWidgets] functions to
  /// run a test.
  Future<Null> runTest(Future<Null> callback());

  /// This is called during test execution before and after the body has been
  /// executed.
  ///
  /// It's used by [AutomatedTestWidgetsFlutterBinding] to drain the microtasks
  /// before the final [pump] that happens during test cleanup.
  void asyncBarrier() {
    TestAsyncUtils.verifyAllScopesClosed();
  }

  Zone _parentZone;
  Completer<Null> _currentTestCompleter;

  void _testCompletionHandler() {
    // This can get called twice, in the case of a Future without listeners failing, and then
    // our main future completing.
    assert(Zone.current == _parentZone);
    assert(_currentTestCompleter != null);
    if (_pendingExceptionDetails != null) {
      FlutterError.dumpErrorToConsole(_pendingExceptionDetails, forceReport: true);
      // test_package.registerException actually just calls the current zone's error handler (that
      // is to say, _parentZone's handleUncaughtError function). FakeAsync doesn't add one of those,
      // but the test package does, that's how the test package tracks errors. So really we could
      // get the same effect here by calling that error handler directly or indeed just throwing.
      // However, we call registerException because that's the semantically correct thing...
      test_package.registerException('Test failed. See exception logs above.', _EmptyStack.instance);
      _pendingExceptionDetails = null;
    }
    if (!_currentTestCompleter.isCompleted)
      _currentTestCompleter.complete(null);
  }

  Future<Null> _runTest(Future<Null> callback()) {
    assert(inTest);
    _oldExceptionHandler = FlutterError.onError;
    int _exceptionCount = 0; // number of un-taken exceptions
    FlutterError.onError = (FlutterErrorDetails details) {
      if (_pendingExceptionDetails != null) {
        if (_exceptionCount == 0) {
          _exceptionCount = 2;
          FlutterError.dumpErrorToConsole(_pendingExceptionDetails, forceReport: true);
        } else {
          _exceptionCount += 1;
        }
        FlutterError.dumpErrorToConsole(details, forceReport: true);
        _pendingExceptionDetails = new FlutterErrorDetails(
          exception: 'Multiple exceptions ($_exceptionCount) were detected during the running of the current test, and at least one was unexpected.',
          library: 'Flutter test framework'
        );
      } else {
        _pendingExceptionDetails = details;
      }
    };
    _currentTestCompleter = new Completer<Null>();
    ZoneSpecification errorHandlingZoneSpecification = new ZoneSpecification(
      handleUncaughtError: (Zone self, ZoneDelegate parent, Zone zone, dynamic exception, StackTrace stack) {
        if (_currentTestCompleter.isCompleted) {
          // Well this is not a good sign.
          // Ideally, once the test has failed we would stop getting errors from the test.
          // However, if someone tries hard enough they could get in a state where this happens.
          // If we silently dropped these errors on the ground, nobody would ever know. So instead
          // we report them to the console. They don't cause test failures, but hopefully someone
          // will see them in the logs at some point.
          FlutterError.dumpErrorToConsole(new FlutterErrorDetails(
            exception: exception,
            stack: stack,
            context: 'running a test (but after the test had completed)',
            library: 'Flutter test framework'
          ), forceReport: true);
          return;
        }
        // This is where test failures, e.g. those in expect(), will end up.
        // Specifically, runUnaryGuarded() will call this synchronously and
        // return our return value if _runTestBody fails synchronously (which it
        // won't, so this never happens), and Future will call this when the
        // Future completes with an error and it would otherwise call listeners
        // if the listener is in a different zone (which it would be for the
        // `whenComplete` handler below), or if the Future completes with an
        // error and the future has no listeners at all.
        // This handler further calls the onError handler above, which sets
        // _pendingExceptionDetails. Nothing gets printed as a result of that
        // call unless we already had an exception pending, because in general
        // we want people to be able to cause the framework to report exceptions
        // and then use takeException to verify that they were really caught.
        // Now, if we actually get here, this isn't going to be one of those
        // cases. We only get here if the test has actually failed. So, once
        // we've carefully reported it, we then immediately end the test by
        // calling the _testCompletionHandler in the _parentZone.
        // We have to manually call _testCompletionHandler because if the Future
        // library calls us, it is maybe _instead_ of calling a registered
        // listener from a different zone. In our case, that would be instead of
        // calling the whenComplete() listener below.
        // We have to call it in the parent zone because if we called it in
        // _this_ zone, the test framework would find this zone was the current
        // zone and helpfully throw the error in this zone, causing us to be
        // directly called again.
        final String treeDump = renderViewElement?.toStringDeep() ?? '<no tree>';
        final StringBuffer expectLine = new StringBuffer();
        final int stackLinesToOmit = reportExpectCall(stack, expectLine);
        FlutterError.reportError(new FlutterErrorDetails(
          exception: exception,
          stack: stack,
          context: 'running a test',
          library: 'Flutter test framework',
          stackFilter: (List<String> frames) {
            return FlutterError.defaultStackFilter(frames.skip(stackLinesToOmit));
          },
          informationCollector: (StringBuffer information) {
            if (stackLinesToOmit > 0)
              information.writeln(expectLine.toString());
            if (showAppDumpInErrors) {
              information.writeln('At the time of the failure, the widget tree looked as follows:');
              information.writeln('# ${treeDump.split("\n").takeWhile((String s) => s != "").join("\n# ")}');
            }
          }
        ));
        assert(_parentZone != null);
        assert(_pendingExceptionDetails != null);
        _parentZone.run(_testCompletionHandler);
      }
    );
    _parentZone = Zone.current;
    Zone testZone = _parentZone.fork(specification: errorHandlingZoneSpecification);
    testZone.runUnaryGuarded(_runTestBody, callback)
      .whenComplete(_testCompletionHandler);
    asyncBarrier(); // When using AutomatedTestWidgetsFlutterBinding, this flushes the microtasks.
    return _currentTestCompleter.future;
  }

  Future<Null> _runTestBody(Future<Null> callback()) async {
    assert(inTest);

    runApp(new Container(key: new UniqueKey(), child: _kPreTestMessage)); // Reset the tree to a known state.
    await pump();

    // run the test
    await callback();
    asyncBarrier(); // drains the microtasks in `flutter test` mode (when using AutomatedTestWidgetsFlutterBinding)

    if (_pendingExceptionDetails == null) {
      // We only try to clean up and verify invariants if we didn't already
      // fail. If we got an exception already, then we instead leave everything
      // alone so that we don't cause more spurious errors.
      runApp(new Container(key: new UniqueKey(), child: _kPostTestMessage)); // Unmount any remaining widgets.
      await pump();
      _verifyInvariants();
    }

    assert(inTest);
    return null;
  }

  void _verifyInvariants() {
    assert(debugAssertNoTransientCallbacks(
      'An animation is still running even after the widget tree was disposed.'
    ));
  }

  /// Called by the [testWidgets] function after a test is executed.
  void postTest() {
    assert(inTest);
    FlutterError.onError = _oldExceptionHandler;
    _pendingExceptionDetails = null;
    _currentTestCompleter = null;
    _parentZone = null;
  }
}

/// A variant of [TestWidgetsFlutterBinding] for executing tests in
/// the `flutter test` environment.
///
/// This binding controls time, allowing tests to verify long
/// animation sequences without having to execute them in real time.
class AutomatedTestWidgetsFlutterBinding extends TestWidgetsFlutterBinding {
  AutomatedTestWidgetsFlutterBinding._();

  @override
  void initInstances() {
    debugPrint = debugPrintSynchronously;
    super.initInstances();
    ui.window.onBeginFrame = null;
  }

  FakeAsync _fakeAsync;
  Clock _clock;

  @override
  test_package.Timeout get defaultTestTimeout => const test_package.Timeout(const Duration(seconds: 5));

  @override
  bool get inTest => _fakeAsync != null;

  @override
  Future<Null> pump([ Duration duration, EnginePhase newPhase = EnginePhase.sendSemanticsTree ]) {
    return TestAsyncUtils.guard(() {
      assert(inTest);
      assert(_clock != null);
      if (duration != null)
        _fakeAsync.elapse(duration);
      _phase = newPhase;
      if (hasScheduledFrame) {
        handleBeginFrame(new Duration(
          milliseconds: _clock.now().millisecondsSinceEpoch
        ));
      }
      _fakeAsync.flushMicrotasks();
      return new Future<Null>.value();
    });
  }

  @override
  Future<Null> idle() {
    Future<Null> result = super.idle();
    _fakeAsync.flushMicrotasks();
    return result;
  }

  EnginePhase _phase = EnginePhase.sendSemanticsTree;

  // Cloned from RendererBinding.beginFrame() but with early-exit semantics.
  @override
  void beginFrame() {
    assert(inTest);
    buildOwner.buildDirtyElements();
    assert(renderView != null);
    pipelineOwner.flushLayout();
    if (_phase == EnginePhase.layout)
      return;
    pipelineOwner.flushCompositingBits();
    if (_phase == EnginePhase.compositingBits)
      return;
    pipelineOwner.flushPaint();
    if (_phase == EnginePhase.paint)
      return;
    renderView.compositeFrame(); // this sends the bits to the GPU
    if (_phase == EnginePhase.composite)
      return;
    if (SemanticsNode.hasListeners) {
      pipelineOwner.flushSemantics();
      if (_phase == EnginePhase.flushSemantics)
        return;
      SemanticsNode.sendSemanticsTree();
    }
    buildOwner.finalizeTree();
  }

  @override
  Future<Null> runTest(Future<Null> callback()) {
    assert(!inTest);
    assert(_fakeAsync == null);
    assert(_clock == null);
    _fakeAsync = new FakeAsync();
    _clock = _fakeAsync.getClock(new DateTime.utc(2015, 1, 1));
    Future<Null> callbackResult;
    _fakeAsync.run((FakeAsync fakeAsync) {
      assert(fakeAsync == _fakeAsync);
      callbackResult = _runTest(callback);
      assert(inTest);
    });
    // callbackResult is a Future that was created in the Zone of the fakeAsync.
    // This means that if we call .then() on it (as the test framework is about to),
    // it will register a microtask to handle the future _in the fake async zone_.
    // To avoid this, we wrap it in a Future that we've created _outside_ the fake
    // async zone.
    return new Future<Null>.value(callbackResult);
  }

  @override
  void asyncBarrier() {
    assert(_fakeAsync != null);
    _fakeAsync.flushMicrotasks();
    super.asyncBarrier();
  }

  @override
  void _verifyInvariants() {
    super._verifyInvariants();
    assert(() {
      'A Timer is still running even after the widget tree was disposed.';
      return _fakeAsync.periodicTimerCount == 0;
    });
    assert(() {
      'A Timer is still running even after the widget tree was disposed.';
      return _fakeAsync.nonPeriodicTimerCount == 0;
    });
    assert(_fakeAsync.microtaskCount == 0); // Shouldn't be possible.
  }

  @override
  void postTest() {
    super.postTest();
    assert(_fakeAsync != null);
    assert(_clock != null);
    _clock = null;
    _fakeAsync = null;
  }

}

/// A variant of [TestWidgetsFlutterBinding] for executing tests in
/// the `flutter run` environment, on a device. This is intended to
/// allow interactive test development.
///
/// This is not the way to run a remote-control test. To run a test on
/// a device from a development computer, see the [flutter_driver]
/// package and the `flutter drive` command.
///
/// This binding overrides the default [SchedulerBinding] behavior to
/// ensure that tests work in the same way in this environment as they
/// would under the [AutomatedTestWidgetsFlutterBinding]. To override
/// this (and see intermediate frames that the test does not
/// explicitly trigger), set [allowAllFrames] to true. (This is likely
/// to make tests fail, though, especially if e.g. they test how many
/// times a particular widget was built.)
///
/// This binding does not support the [EnginePhase] argument to
/// [pump]. (There would be no point setting it to a value that
/// doesn't trigger a paint, since then you could not see anything
/// anyway.)
class LiveTestWidgetsFlutterBinding extends TestWidgetsFlutterBinding {
  LiveTestWidgetsFlutterBinding._();

  @override
  bool get inTest => _inTest;
  bool _inTest = false;

  @override
  test_package.Timeout get defaultTestTimeout => test_package.Timeout.none;

  Completer<Null> _pendingFrame;
  bool _expectingFrame = false;

  /// Whether to have [pump] with a duration only pump a single frame
  /// (as would happen in a normal test environment using
  /// [AutomatedTestWidgetsFlutterBinding]), or whether to instead
  /// pump every frame that the system requests during any
  /// asynchronous pause in the test (as would normally happen when
  /// running an application with [WidgetsFlutterBinding]).
  ///
  /// `false` is the default behavior, which is to only pump once.
  ///
  /// `true` allows all frame requests from the engine to be serviced.
  ///
  /// Setting this to `true` means pumping extra frames, which might
  /// involve calling builders more, or calling paint callbacks more,
  /// etc, which might interfere with the test. If you know your test
  /// file wouldn't be affected by this, you can set it to true
  /// persistently in that particular test file. To set this to `true`
  /// while still allowing the test file to work as a normal test, add
  /// the following code to your test file at the top of your `void
  /// main() { }` function, before calls to `testWidgets`:
  ///
  /// ```dart
  /// TestWidgetsFlutterBinding binding = TestWidgetsFlutterBinding.ensureInitialized();
  /// if (binding is LiveTestWidgetsFlutterBinding)
  ///   binding.allowAllFrames = true;
  /// ```
  bool allowAllFrames = false;

  @override
  void handleBeginFrame(Duration rawTimeStamp) {
    if (_expectingFrame || allowAllFrames)
      super.handleBeginFrame(rawTimeStamp);
    if (_expectingFrame) {
      assert(_pendingFrame != null);
      _pendingFrame.complete(); // unlocks the test API
      _pendingFrame = null;
      _expectingFrame = false;
    } else {
      ui.window.scheduleFrame();
    }
  }

  @override
  Future<Null> pump([ Duration duration, EnginePhase newPhase = EnginePhase.sendSemanticsTree ]) {
    assert(newPhase == EnginePhase.sendSemanticsTree);
    assert(inTest);
    assert(!_expectingFrame);
    assert(_pendingFrame == null);
    return TestAsyncUtils.guard(() {
      if (duration != null) {
        new Timer(duration, () {
          _expectingFrame = true;
          scheduleFrame();
        });
      } else {
        _expectingFrame = true;
        scheduleFrame();
      }
      _pendingFrame = new Completer<Null>();
      return _pendingFrame.future;
    });
  }

  @override
  Future<Null> runTest(Future<Null> callback()) async {
    assert(!inTest);
    _inTest = true;
    return _runTest(callback);
  }

  @override
  void postTest() {
    super.postTest();
    assert(!_expectingFrame);
    assert(_pendingFrame == null);
    _inTest = false;
  }

  @override
  ViewConfiguration createViewConfiguration() {
    final double actualWidth = ui.window.size.width * ui.window.devicePixelRatio;
    final double actualHeight = ui.window.size.height * ui.window.devicePixelRatio;
    final double desiredWidth = _kTestViewportSize.width;
    final double desiredHeight = _kTestViewportSize.height;
    double scale, shiftX, shiftY;
    if ((actualWidth / actualHeight) > (desiredWidth / desiredHeight)) {
      scale = actualHeight / desiredHeight;
      shiftX = (actualWidth - desiredWidth * scale) / 2.0;
      shiftY = 0.0;
    } else {
      scale = actualWidth / desiredWidth;
      shiftX = 0.0;
      shiftY = (actualHeight - desiredHeight * scale) / 2.0;
    }
    final Matrix4 matrix = new Matrix4.compose(
      new Vector3(shiftX, shiftY, 0.0), // translation
      new Quaternion.identity(), // rotation
      new Vector3(scale, scale, 0.0) // scale
    );
    return new _TestViewConfiguration(matrix);
  }
}

class _TestViewConfiguration extends ViewConfiguration {
  _TestViewConfiguration(this.matrix) : super(size: _kTestViewportSize);

  final Matrix4 matrix;

  @override
  Matrix4 toMatrix() => matrix;

  @override
  String toString() => 'TestViewConfiguration';
}

class _EmptyStack implements StackTrace {
  const _EmptyStack._();
  static const _EmptyStack instance = const _EmptyStack._();
  @override
  String toString() => '';
}