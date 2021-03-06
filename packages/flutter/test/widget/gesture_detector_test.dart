// Copyright 2015 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';

void main() {
  testWidgets('Uncontested scrolls start immediately', (WidgetTester tester) async {
    bool didStartDrag = false;
    double updatedDragDelta;
    bool didEndDrag = false;

    Widget widget = new GestureDetector(
      onVerticalDragStart: (_) {
        didStartDrag = true;
      },
      onVerticalDragUpdate: (double scrollDelta) {
        updatedDragDelta = scrollDelta;
      },
      onVerticalDragEnd: (Velocity velocity) {
        didEndDrag = true;
      },
      child: new Container(
        decoration: const BoxDecoration(
          backgroundColor: const Color(0xFF00FF00)
        )
      )
    );

    await tester.pumpWidget(widget);
    expect(didStartDrag, isFalse);
    expect(updatedDragDelta, isNull);
    expect(didEndDrag, isFalse);

    Point firstLocation = new Point(10.0, 10.0);
    TestGesture gesture = await tester.startGesture(firstLocation, pointer: 7);
    expect(didStartDrag, isTrue);
    didStartDrag = false;
    expect(updatedDragDelta, isNull);
    expect(didEndDrag, isFalse);

    Point secondLocation = new Point(10.0, 9.0);
    await gesture.moveTo(secondLocation);
    expect(didStartDrag, isFalse);
    expect(updatedDragDelta, -1.0);
    updatedDragDelta = null;
    expect(didEndDrag, isFalse);

    await gesture.up();
    expect(didStartDrag, isFalse);
    expect(updatedDragDelta, isNull);
    expect(didEndDrag, isTrue);
    didEndDrag = false;

    await tester.pumpWidget(new Container());
  });

  testWidgets('Match two scroll gestures in succession', (WidgetTester tester) async {
    int gestureCount = 0;
    double dragDistance = 0.0;

    Point downLocation = new Point(10.0, 10.0);
    Point upLocation = new Point(10.0, 20.0);

    Widget widget = new GestureDetector(
      onVerticalDragUpdate: (double delta) { dragDistance += delta; },
      onVerticalDragEnd: (Velocity velocity) { gestureCount += 1; },
      onHorizontalDragUpdate: (_) { fail("gesture should not match"); },
      onHorizontalDragEnd: (Velocity velocity) { fail("gesture should not match"); },
      child: new Container(
        decoration: const BoxDecoration(
          backgroundColor: const Color(0xFF00FF00)
        )
      )
    );
    await tester.pumpWidget(widget);

    TestGesture gesture = await tester.startGesture(downLocation, pointer: 7);
    await gesture.moveTo(upLocation);
    await gesture.up();

    gesture = await tester.startGesture(downLocation, pointer: 7);
    await gesture.moveTo(upLocation);
    await gesture.up();

    expect(gestureCount, 2);
    expect(dragDistance, 20.0);

    await tester.pumpWidget(new Container());
  });

  testWidgets('Pan doesn\'t crash', (WidgetTester tester) async {
    bool didStartPan = false;
    Offset panDelta;
    bool didEndPan = false;

    await tester.pumpWidget(
      new GestureDetector(
        onPanStart: (_) {
          didStartPan = true;
        },
        onPanUpdate: (Offset delta) {
          panDelta = delta;
        },
        onPanEnd: (_) {
          didEndPan = true;
        },
        child: new Container(
          decoration: const BoxDecoration(
            backgroundColor: const Color(0xFF00FF00)
          )
        )
      )
    );

    expect(didStartPan, isFalse);
    expect(panDelta, isNull);
    expect(didEndPan, isFalse);

    await tester.scrollAt(new Point(10.0, 10.0), new Offset(20.0, 30.0));

    expect(didStartPan, isTrue);
    expect(panDelta.dx, 20.0);
    expect(panDelta.dy, 30.0);
    expect(didEndPan, isTrue);
  });

  testWidgets('Translucent', (WidgetTester tester) async {
    bool didReceivePointerDown;
    bool didTap;

    Future<Null> pumpWidgetTree(HitTestBehavior behavior) {
      return tester.pumpWidget(
        new Stack(
          children: <Widget>[
            new Listener(
              onPointerDown: (_) {
                didReceivePointerDown = true;
              },
              child: new Container(
                width: 100.0,
                height: 100.0,
                decoration: const BoxDecoration(
                  backgroundColor: const Color(0xFF00FF00)
                )
              )
            ),
            new Container(
              width: 100.0,
              height: 100.0,
              child: new GestureDetector(
                onTap: () {
                  didTap = true;
                },
                behavior: behavior
              )
            )
          ]
        )
      );
    }

    didReceivePointerDown = false;
    didTap = false;
    await pumpWidgetTree(null);
    await tester.tapAt(new Point(10.0, 10.0));
    expect(didReceivePointerDown, isTrue);
    expect(didTap, isTrue);

    didReceivePointerDown = false;
    didTap = false;
    await pumpWidgetTree(HitTestBehavior.deferToChild);
    await tester.tapAt(new Point(10.0, 10.0));
    expect(didReceivePointerDown, isTrue);
    expect(didTap, isFalse);

    didReceivePointerDown = false;
    didTap = false;
    await pumpWidgetTree(HitTestBehavior.opaque);
    await tester.tapAt(new Point(10.0, 10.0));
    expect(didReceivePointerDown, isFalse);
    expect(didTap, isTrue);

    didReceivePointerDown = false;
    didTap = false;
    await pumpWidgetTree(HitTestBehavior.translucent);
    await tester.tapAt(new Point(10.0, 10.0));
    expect(didReceivePointerDown, isTrue);
    expect(didTap, isTrue);

  });
}
