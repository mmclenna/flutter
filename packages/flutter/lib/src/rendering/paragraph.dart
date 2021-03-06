// Copyright 2015 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';

import 'box.dart';
import 'object.dart';
import 'semantics.dart';

/// How overflowing text should be handled.
enum TextOverflow {
  /// Clip the overflowing text to fix its container.
  clip,

  /// Fade the overflowing text to transparent.
  fade,

  /// Use an ellipsis to indicate that the text has overflowed.
  ellipsis,
}

/// A render object that displays a paragraph of text
class RenderParagraph extends RenderBox {
  /// Creates a paragraph render object.
  ///
  /// The [text], [overflow], and [softWrap] arguments must not be null.
  RenderParagraph(TextSpan text, {
    TextAlign textAlign,
    TextOverflow overflow: TextOverflow.clip,
    bool softWrap: true
  }) : _softWrap = softWrap,
       _overflow = overflow,
       _textPainter = new TextPainter(text: text, textAlign: textAlign) {
    assert(text != null);
    assert(text.debugAssertValid());
    assert(overflow != null);
    assert(softWrap != null);
  }

  final TextPainter _textPainter;

  /// The text to display
  TextSpan get text => _textPainter.text;
  set text(TextSpan value) {
    assert(value != null);
    if (_textPainter.text == value)
      return;
    _textPainter.text = value;
    _overflowPainter = null;
    _overflowShader = null;
    markNeedsLayout();
  }

  /// How the text should be aligned horizontally.
  TextAlign get textAlign => _textPainter.textAlign;
  set textAlign(TextAlign value) {
    if (_textPainter.textAlign == value)
      return;
    _textPainter.textAlign = value;
    markNeedsPaint();
  }

  /// Whether the text should break at soft line breaks.
  ///
  /// If false, the glyphs in the text will be positioned as if there was unlimited horizontal space.
  bool get softWrap => _softWrap;
  bool _softWrap;
  set softWrap(bool value) {
    assert(value != null);
    if (_softWrap == value)
      return;
    _softWrap = value;
    markNeedsLayout();
  }

  /// How visual overflow should be handled.
  TextOverflow get overflow => _overflow;
  TextOverflow _overflow;
  set overflow(TextOverflow value) {
    assert(value != null);
    if (_overflow == value)
      return;
    _overflow = value;
    markNeedsPaint();
  }

  void _layoutText(BoxConstraints constraints) {
    assert(constraints != null);
    assert(constraints.debugAssertIsValid());
    _textPainter.layout(minWidth: constraints.minWidth, maxWidth: _softWrap ? constraints.maxWidth : double.INFINITY);
  }

  @override
  double getMinIntrinsicWidth(BoxConstraints constraints) {
    _layoutText(constraints);
    return constraints.constrainWidth(_textPainter.minIntrinsicWidth);
  }

  @override
  double getMaxIntrinsicWidth(BoxConstraints constraints) {
    _layoutText(constraints);
    return constraints.constrainWidth(_textPainter.maxIntrinsicWidth);
  }

  double _getIntrinsicHeight(BoxConstraints constraints) {
    _layoutText(constraints);
    return constraints.constrainHeight(_textPainter.height);
  }

  @override
  double getMinIntrinsicHeight(BoxConstraints constraints) {
    assert(constraints.debugAssertIsValid());
    return _getIntrinsicHeight(constraints);
  }

  @override
  double getMaxIntrinsicHeight(BoxConstraints constraints) {
    assert(constraints.debugAssertIsValid());
    return _getIntrinsicHeight(constraints);
  }

  @override
  double computeDistanceToActualBaseline(TextBaseline baseline) {
    assert(!needsLayout);
    _layoutText(constraints);
    return _textPainter.computeDistanceToActualBaseline(baseline);
  }

  @override
  bool hitTestSelf(Point position) => true;

  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    if (event is! PointerDownEvent)
      return;
    _layoutText(constraints);
    Offset offset = entry.localPosition.toOffset();
    TextPosition position = _textPainter.getPositionForOffset(offset);
    TextSpan span = _textPainter.text.getSpanForPosition(position);
    span?.recognizer?.addPointer(event);
  }

  bool _hasVisualOverflow = false;
  TextPainter _overflowPainter;
  ui.Shader _overflowShader;

  @override
  void performLayout() {
    _layoutText(constraints);
    size = constraints.constrain(_textPainter.size);

    final bool didOverflowWidth = size.width < _textPainter.width;
    // TODO(abarth): We're only measuring the sizes of the line boxes here. If
    // the glyphs draw outside the line boxes, we might think that there isn't
    // visual overflow when there actually is visual overflow. This can become
    // a problem if we start having horizontal overflow and introduce a clip
    // that affects the actual (but undetected) vertical overflow.
    _hasVisualOverflow = didOverflowWidth || size.height < _textPainter.height;
    if (didOverflowWidth) {
      switch (_overflow) {
        case TextOverflow.clip:
          _overflowPainter = null;
          _overflowShader = null;
          break;
        case TextOverflow.fade:
        case TextOverflow.ellipsis:
          _overflowPainter ??= new TextPainter(
            text: new TextSpan(style: _textPainter.text.style, text: '\u2026')
          )..layout();
          final double overflowUnit = _overflowPainter.width;
          double fadeEnd = size.width;
          if (_overflow == TextOverflow.ellipsis)
            fadeEnd -= overflowUnit / 2.0;
          final double fadeStart = fadeEnd - _overflowPainter.width;
          // TODO(abarth): This shader has an LTR bias.
          _overflowShader = new ui.Gradient.linear(
            <Point>[new Point(fadeStart, 0.0), new Point(fadeEnd, 0.0)],
            <Color>[const Color(0xFFFFFFFF), const Color(0x00FFFFFF)]
          );
          break;
      }
    } else {
      _overflowPainter = null;
      _overflowShader = null;
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    // Ideally we could compute the min/max intrinsic width/height with a
    // non-destructive operation. However, currently, computing these values
    // will destroy state inside the painter. If that happens, we need to
    // get back the correct state by calling _layout again.
    //
    // TODO(abarth): Make computing the min/max intrinsic width/height
    // a non-destructive operation.
    //
    // If you remove this call, make sure that changing the textAlign still
    // works properly.
    _layoutText(constraints);
    final Canvas canvas = context.canvas;
    if (_hasVisualOverflow) {
      final Rect bounds = offset & size;
      if (_overflowPainter != null)
        canvas.saveLayer(bounds, new Paint());
      else
        canvas.save();
      canvas.clipRect(bounds);
    }
    _textPainter.paint(canvas, offset);
    if (_hasVisualOverflow) {
      if (_overflowShader != null) {
        canvas.translate(offset.dx, offset.dy);
        Paint paint = new Paint()
          ..transferMode = TransferMode.modulate
          ..shader = _overflowShader;
        canvas.drawRect(Point.origin & size, paint);
        if (_overflow == TextOverflow.ellipsis) {
          // TODO(abarth): This paint offset has an LTR bias.
          Offset ellipseOffset = new Offset(size.width - _overflowPainter.width, 0.0);
          _overflowPainter.paint(canvas, ellipseOffset);
        }
      }
      canvas.restore();
    }
  }

  @override
  Iterable<SemanticAnnotator> getSemanticAnnotators() sync* {
    yield (SemanticsNode node) {
      node.label = text.toPlainText();
    };
  }

  @override
  String debugDescribeChildren(String prefix) {
    return '$prefix \u2558\u2550\u2566\u2550\u2550 text \u2550\u2550\u2550\n'
           '${text.toString("$prefix   \u2551 ")}' // TextSpan includes a newline
           '$prefix   \u255A\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\n'
           '$prefix\n';
  }
}
