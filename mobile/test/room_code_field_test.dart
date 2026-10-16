import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamenight/widgets/room_code_field.dart';
import 'package:gamenight/theme.dart';

void main() {
  testWidgets(
      'six slots keep cursor at first position, normalize paste and allow corrections',
      (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    String? changed;
    await tester.pumpWidget(MaterialApp(
        theme: gameNightTheme(),
        home: Scaffold(
            body: Center(
                child: SizedBox(
                    width: 300,
                    child: RoomCodeField(
                        controller: controller,
                        onChanged: (v) => changed = v))))));
    for (var i = 0; i < 6; i++) {
      expect(find.byKey(ValueKey('room-code-slot-$i')), findsOneWidget);
    }
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(controller.selection.extentOffset, 0);
    expect(tester.getCenter(find.byKey(const ValueKey('room-code-cursor'))).dx,
        tester.getCenter(find.byKey(const ValueKey('room-code-slot-0'))).dx);
    await tester.enterText(find.byType(TextField), 'ab-23 cd!');
    await tester.pump();
    expect(controller.text, 'AB23CD');
    expect(changed, 'AB23CD');
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(controller.text, 'AB23C');
    await tester.enterText(find.byType(TextField), 'XYZ987EXTRA');
    await tester.pump();
    expect(controller.text, 'XYZ987');
    await tester.pumpWidget(const SizedBox());
  });
}
