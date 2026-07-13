import 'dart:convert';
import 'dart:typed_data';

import 'package:flterm/src/rendering/terminal_semantics_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:libghostty/libghostty.dart';

void main() {
  test('accessible snapshot preserves subsequent terminal dirty state', () {
    final terminal = Terminal(cols: 20, rows: 3);
    final renderState = RenderState();
    final snapshot = TerminalSemanticsSnapshot();
    addTearDown(() {
      snapshot.dispose();
      renderState.dispose();
      terminal.dispose();
    });

    terminal.write(Uint8List.fromList(utf8.encode('visible')));
    expect(renderState.update(terminal), isNot(DirtyState.clean));
    expect(snapshot.visibleText(renderState), contains('visible'));

    renderState.dirty = DirtyState.clean;
    terminal.write(Uint8List.fromList(utf8.encode(' updated')));
    expect(renderState.update(terminal), isNot(DirtyState.clean));
  });
}
