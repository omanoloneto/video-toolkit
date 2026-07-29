import 'package:flutter_test/flutter_test.dart';

import 'package:audio_video_editor/main.dart';

void main() {
  testWidgets('App builds', (WidgetTester tester) async {
    await tester.pumpWidget(const AudioVideoEditorApp());
    expect(find.text('Editor de Faixas'), findsOneWidget);
  });
}
