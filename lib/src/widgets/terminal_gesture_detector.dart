import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:libghostty/libghostty.dart'
    show MouseAction, MouseButton, MouseTracking, Position;
import 'package:meta/meta.dart';

import '../foundation.dart';
import '../links/link_settings.dart';
import 'link_interaction.dart';
import 'terminal_raw_gesture_detector.dart';
import 'terminal_view_binding.dart';

/// Interprets gestures as terminal actions: selection, mouse tracking
/// reports, and focus requests.
///
/// Reports all gestures to [TerminalViewBinding] which handles
/// snapping, scroll offset, and encoding.
@internal
class TerminalGestureDetector extends StatefulWidget {
  final Widget child;
  final int visibleRows;
  final CellMetrics metrics;
  final TerminalViewBinding binding;
  final TerminalGestureSettings settings;
  final LinkInteraction links;
  final ValueChanged<ActivatedLink>? onLinkActivate;
  final ScrollController? scrollController;

  const TerminalGestureDetector({
    super.key,
    required this.child,
    this.visibleRows = 0,
    required this.metrics,
    required this.binding,
    required this.links,
    this.onLinkActivate,
    this.scrollController,
    this.settings = const TerminalGestureSettings(),
  });

  @override
  State<TerminalGestureDetector> createState() =>
      _TerminalGestureDetectorState();
}

class _TerminalGestureDetectorState extends State<TerminalGestureDetector> {
  _DragState? _drag;
  Position? _pressCell;
  var _linkPressActive = false;
  Timer? _autoScrollTimer;
  final Map<int, MouseButton> _trackedButtons = {};
  double _wheelRemainder = 0;

  TerminalViewBinding get _binding => widget.binding;

  @override
  Widget build(BuildContext context) {
    final tracked = _binding.mouseTracking != MouseTracking.none;

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: tracked ? _handleTrackedDown : null,
      onPointerMove: tracked ? _handleTrackedMove : null,
      onPointerUp: tracked ? _handleTrackedUp : null,
      onPointerCancel: tracked ? _handleTrackedCancel : null,
      onPointerHover: tracked ? _handleTrackedHover : null,
      onPointerSignal: tracked ? _handleTrackedSignal : null,
      child: TerminalRawGestureDetector(
        onTapDown: _handleTapDown,
        onTapUp: _handleTapUp,
        onDragStart: _handleDragStart,
        onDragUpdate: _handleDragUpdate,
        onDragEnd: _handleDragEnd,
        onLongPressStart: _handleLongPressStart,
        onLongPressMoveUpdate: _handleLongPressMoveUpdate,
        onLongPressUp: _handleLongPressUp,
        child: widget.child,
      ),
    );
  }

  @override
  void didUpdateWidget(TerminalGestureDetector oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.metrics != oldWidget.metrics ||
        widget.binding != oldWidget.binding) {
      _binding.clearSelection();
      _stopAutoScroll();
      _drag = null;
      _pressCell = null;
      _cancelLinkPress();
    }
  }

  @override
  void dispose() {
    _autoScrollTimer?.cancel();
    _trackedButtons.clear();
    super.dispose();
  }

  void _autoScrollTick(Timer timer) {
    final scrollController = widget.scrollController;
    if (scrollController == null || !scrollController.hasClients) return;

    final drag = _drag;
    if (drag == null) {
      _stopAutoScroll();
      return;
    }

    _binding.updateSelectionAutoscroll(
      cell: drag.cell,
      localPosition: drag.localPosition,
      rectangle: drag.lastRectangle,
    );
  }

  void _cancelLinkPress() {
    if (!_linkPressActive) return;
    _linkPressActive = false;
    widget.links.cancel();
  }

  void _cancelSelectionPress() {
    if (_pressCell == null) return;
    _binding.cancelSelectionGesture();
    _pressCell = null;
  }

  int _clampInt(int value, int min, int max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }

  void _endDrag() {
    final drag = _drag;
    if (drag != null) {
      _releaseSelectionPress(drag.cell);
    } else {
      _releaseSelectionPress();
    }
    _stopAutoScroll();
    _drag = null;
    _cancelLinkPress();
  }

  void _handleDragEnd() => _endDrag();

  void _handleDragStart(DragStartDetails details) {
    _binding.requestFocus();
    _cancelLinkPress();
    if (_isMouseTracked(HardwareKeyboard.instance.isShiftPressed)) {
      return;
    }
    if (!widget.settings.dragSelection) {
      _cancelSelectionPress();
      return;
    }

    _startDrag(details.localPosition, beginPress: _pressCell == null);
  }

  void _handleDragUpdate(DragUpdateDetails details) {
    if (_drag != null) _updateDrag(details.localPosition);
  }

  void _handleLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    if (_drag != null) _updateDrag(details.localPosition);
  }

  void _handleLongPressStart(LongPressStartDetails details) {
    _binding.requestFocus();
    if (_isMouseTracked(false)) {
      _cancelSelectionPress();
      return;
    }
    if (!widget.settings.longPressSelection) {
      _cancelSelectionPress();
      return;
    }
    _startDrag(
      details.localPosition,
      rectangle: widget.settings.longPressSelectionShape == .rectangle,
      beginPress: _pressCell == null,
    );
    unawaited(Feedback.forLongPress(context));
  }

  void _handleLongPressUp() => _endDrag();

  void _handleSelectionPress(Offset position) {
    final cell = widget.metrics.cellAt(position);
    _binding.handleSelectionPress(
      cell: cell,
      localPosition: position,
      settings: widget.settings,
    );
    _pressCell = cell;
  }

  void _handleTapDown(TapDownDetails details) {
    _binding.requestFocus();
    if (_isMouseTracked(HardwareKeyboard.instance.isShiftPressed)) {
      return;
    }
    if (widget.links.handlePress(
      localPosition: details.localPosition,
      metrics: widget.metrics,
      pointerKind: details.kind ?? .mouse,
      virtualMods: _binding.virtualMods,
    )) {
      _linkPressActive = true;
      _cancelSelectionPress();
      return;
    }
    _handleSelectionPress(details.localPosition);
  }

  void _handleTapUp(TapUpDetails details) {
    if (_linkPressActive) {
      _linkPressActive = false;
      final link = widget.links.handleRelease(
        localPosition: details.localPosition,
        metrics: widget.metrics,
      );
      if (link != null) widget.onLinkActivate?.call(link);
      return;
    }
    if (_pressCell == null &&
        _isMouseTracked(HardwareKeyboard.instance.isShiftPressed)) {
      return;
    }
    _releaseSelectionPress(widget.metrics.cellAt(details.localPosition));
  }

  void _handleTrackedDown(PointerDownEvent event) {
    if (!_isMouseTracked(HardwareKeyboard.instance.isShiftPressed)) {
      return;
    }
    final button = _mouseButton(event.buttons);
    _trackedButtons[event.pointer] = button;
    _sendMouseEvent(.press, event.localPosition, button: button);
  }

  void _handleTrackedMove(PointerMoveEvent event) {
    if (!_isMouseTracked(HardwareKeyboard.instance.isShiftPressed)) {
      return;
    }
    _sendMouseEvent(
      .motion,
      event.localPosition,
      button: _trackedButtons[event.pointer] ?? _mouseButton(event.buttons),
    );
  }

  void _handleTrackedUp(PointerUpEvent event) {
    final button = _trackedButtons.remove(event.pointer);
    if (button == null) return;
    _sendMouseEvent(.release, event.localPosition, button: button);
  }

  void _handleTrackedCancel(PointerCancelEvent event) {
    final button = _trackedButtons.remove(event.pointer);
    if (button == null) return;
    _sendMouseEvent(.release, event.localPosition, button: button);
  }

  void _handleTrackedHover(PointerHoverEvent event) {
    if (event.kind == .touch ||
        !_isMouseTracked(HardwareKeyboard.instance.isShiftPressed)) {
      return;
    }
    _sendMouseEvent(.motion, event.localPosition, button: null);
  }

  void _handleTrackedSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent ||
        event.kind == .touch ||
        !_isMouseTracked(HardwareKeyboard.instance.isShiftPressed)) {
      return;
    }
    GestureBinding.instance.pointerSignalResolver.register(event, (resolved) {
      final scroll = resolved as PointerScrollEvent;
      final cellHeight = widget.metrics.cellHeight;
      if (cellHeight <= 0) return;
      _wheelRemainder += scroll.scrollDelta.dy / cellHeight;
      final lines = _wheelRemainder.truncate();
      _wheelRemainder -= lines;
      if (lines == 0) return;
      final button = lines < 0 ? MouseButton.four : MouseButton.five;
      for (var i = 0; i < lines.abs(); i++) {
        _sendMouseEvent(.press, scroll.localPosition, button: button);
      }
    });
  }

  bool _isBlockModifierPressed() {
    final modifier = widget.settings.blockSelectionModifier;
    if (modifier == null) return false;
    final keyboard = HardwareKeyboard.instance;
    final mods = _binding.virtualMods;
    return switch (modifier) {
      .alt => keyboard.isAltPressed || mods.hasAlt,
      .meta => keyboard.isMetaPressed || mods.hasSuper,
      .shift => keyboard.isShiftPressed || mods.hasShift,
      .control => keyboard.isControlPressed || mods.hasCtrl,
    };
  }

  bool _isMouseTracked(bool shift) {
    return _binding.mouseTracking != .none &&
        !shift &&
        !_binding.virtualMods.hasShift;
  }

  void _releaseSelectionPress([Position? cell]) {
    cell ??= _pressCell;
    if (cell == null) return;
    _binding.handleSelectionRelease(cell);
    _pressCell = null;
  }

  MouseButton _mouseButton(int buttons) {
    if (buttons & kSecondaryButton != 0) return .right;
    if (buttons & kMiddleMouseButton != 0) return .middle;
    if (buttons & kBackMouseButton != 0) return .four;
    if (buttons & kForwardMouseButton != 0) return .five;
    if (buttons & kPrimaryButton != 0) return .left;
    return .unknown;
  }

  void _sendMouseEvent(
    MouseAction action,
    Offset position, {
    required MouseButton? button,
  }) {
    _binding.handleMouseEvent((
      action: action,
      button: button,
      pixelX: position.dx,
      pixelY: position.dy,
    ));
  }

  void _startAutoScroll() {
    if (_autoScrollTimer != null) return;
    _autoScrollTimer = Timer.periodic(
      const Duration(milliseconds: 50),
      _autoScrollTick,
    );
  }

  void _startDrag(
    Offset position, {
    bool rectangle = false,
    bool beginPress = false,
  }) {
    final cell = widget.metrics.cellAt(position);
    final block = rectangle || _isBlockModifierPressed();
    _drag = _DragState(cell, position, baseRectangle: block);
    if (beginPress) _handleSelectionPress(position);
  }

  void _stopAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
  }

  void _updateDrag(Offset position) {
    final drag = _drag;
    if (drag == null) return;
    final cell = widget.metrics.cellAt(position);
    drag.cell = cell;
    drag.localPosition = position;

    final visibleRows = widget.visibleRows;
    if (visibleRows > 0) {
      if (cell.row < 0) {
        _startAutoScroll();
      } else if (cell.row >= visibleRows) {
        _startAutoScroll();
      } else {
        _stopAutoScroll();
      }
    }

    final clampedRow = visibleRows > 0
        ? _clampInt(cell.row, 0, visibleRows - 1)
        : cell.row;
    final clampedCell = Position(row: clampedRow, col: cell.col);
    final rectangle = drag.baseRectangle || _isBlockModifierPressed();
    if (clampedCell == drag.lastCell && rectangle == drag.lastRectangle) {
      return;
    }
    drag.lastCell = clampedCell;
    drag.lastRectangle = rectangle;

    _binding.updateSelectionDrag(
      cell: clampedCell,
      localPosition: position,
      rectangle: rectangle,
    );
  }
}

class _DragState {
  Position cell;
  Offset localPosition;
  final bool baseRectangle;
  bool lastRectangle;
  Position? lastCell;

  _DragState(this.cell, this.localPosition, {required this.baseRectangle})
    : lastRectangle = baseRectangle;
}
