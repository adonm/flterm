import 'package:libghostty/libghostty.dart';

/// Reusable plain-text view of an already-synchronized terminal render state.
final class TerminalSemanticsSnapshot {
  final _rows = RowIterator();
  final _cells = CellIterator();

  String visibleText(RenderState state) {
    _rows.reset(state);
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
  }
}
