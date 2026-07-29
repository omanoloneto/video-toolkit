import 'package:flutter_test/flutter_test.dart';

import 'package:video_toolkit/main.dart';

void main() {
  testWidgets('App builds', (WidgetTester tester) async {
    await tester.pumpWidget(const AudioVideoEditorApp());
    expect(find.text('Video Toolkit'), findsOneWidget);
  });
}
