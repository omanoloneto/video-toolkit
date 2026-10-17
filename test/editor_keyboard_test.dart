import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_toolkit/widgets/editor_keyboard.dart';

const _field = Key('field');
const _background = Key('background');

void main() {
  late List<LogicalKeyboardKey> received;
  late ValueNotifier<bool> showField;

  setUp(() {
    received = [];
    showField = ValueNotifier(true);
  });

  Widget app() => FluentApp(
        home: EditorKeyboard(
          onKey: (event) {
            received.add(event.logicalKey);
            return KeyEventResult.handled;
          },
          child: ValueListenableBuilder<bool>(
            valueListenable: showField,
            builder: (context, visible, _) => Column(
              children: [
                if (visible)
                  const SizedBox(width: 200, child: TextBox(key: _field)),
                const ColoredBox(
                  key: _background,
                  color: Color(0x00000000),
                  child: SizedBox(width: 300, height: 200),
                ),
              ],
            ),
          ),
        ),
      );

  testWidgets('space reaches the editor right after opening', (tester) async {
    await tester.pumpWidget(app());
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(received, [LogicalKeyboardKey.space]);
  });

  testWidgets('shortcuts are ignored while a text field is focused',
      (tester) async {
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(_field));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(received, isEmpty);
  });

  testWidgets('submitting a text field gives the shortcuts back',
      (tester) async {
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(_field));
    await tester.enterText(find.byKey(_field), '1:30');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(received, [LogicalKeyboardKey.space]);
  });

  testWidgets('clicking outside a text field gives the shortcuts back',
      (tester) async {
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(_field));
    await tester.pump();
    await tester.tap(find.byKey(_background));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    expect(received, [LogicalKeyboardKey.keyS]);

    // and clicking back into the field still lets the user type
    await tester.tap(find.byKey(_field));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(received, [LogicalKeyboardKey.keyS]);
  });

  testWidgets('a focused text field that disappears gives the shortcuts back',
      (tester) async {
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(_field));
    await tester.pump();
    showField.value = false;
    await tester.pump();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    expect(received, [LogicalKeyboardKey.delete]);
  });

  testWidgets('keys pressed with Ctrl or Meta are not shortcuts',
      (tester) async {
    await tester.pumpWidget(app());
    for (final modifier in [
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.metaLeft,
    ]) {
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(modifier);
    }
    expect(received, isEmpty);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    expect(received, [LogicalKeyboardKey.keyS]);
  });
}
