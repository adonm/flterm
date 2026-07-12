import 'package:libghostty/libghostty.dart';

/// Reusable plain-text snapshot of the visible terminal viewport.
final class TerminalSemanticsSnapshot {
  final _state = RenderState();
  final _rows = RowIterator();
  final _cells = CellIterator();

  String visibleText(Terminal terminal) {
    _state.update(terminal);
    _rows.reset(_state);
    final output = StringBuffer();

    while (_rows.next()) {
      _cells.reset(_rows);
      final line = StringBuffer();
      while (_cells.next()) {
        if (_cells.wide == CellWidth.spacerTail) continue;
        final width = _cells.wide == CellWidth.wide ? 2 : 1;
        final content = _cells.style.invisible ? '' : _cells.content;
        line.write(content.isEmpty ? ' ' * width : content);
      }
      output.write(line.toString().trimRight());
      if (!_rows.wrap) output.writeln();
    }

    return output.toString().trimRight();
  }

  void dispose() {
    _cells.dispose();
    _rows.dispose();
    _state.dispose();
  }
}
