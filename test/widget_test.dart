// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:turtleneck_checker/main.dart';

void main() {
  testWidgets('renders posture checker home screen', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('사진으로 거북목 자세를 분석합니다.'), findsOneWidget);
    expect(find.text('AI 설정'), findsOneWidget);
    expect(find.text('현재 모델: gpt-4.1-mini'), findsOneWidget);
    expect(find.text('입력 정보'), findsOneWidget);
    expect(find.text('AI 설정 열기'), findsOneWidget);
    expect(find.text('자세 분석 시작'), findsOneWidget);
    expect(find.text('아직 분석 결과가 없습니다.'), findsOneWidget);
  });
}
