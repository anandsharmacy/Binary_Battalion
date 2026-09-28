import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ner_logistics/shared/widgets/glass_surface.dart';

void main() {
  Widget app(Widget child, {bool highContrast = false}) => MediaQuery(
    data: MediaQueryData(highContrast: highContrast),
    child: MaterialApp(home: Scaffold(body: child)),
  );

  testWidgets('GlassSurface renders a BackdropFilter by default', (
    tester,
  ) async {
    await tester.pumpWidget(app(const GlassSurface(child: Text('glass'))));
    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets('GlassSurface renders no BackdropFilter under high contrast', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(const GlassSurface(child: Text('glass')), highContrast: true),
    );
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('glass'), findsOneWidget);
  });
}
