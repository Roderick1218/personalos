// 冒烟测试: 应用能启动且不崩溃就算过。
// 真正的界面/数据流测试是通过 adb 装到真机上手动跑的 (见项目说明)。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:personasystem/main.dart';

void main() {
  testWidgets('App boots without throwing', (WidgetTester tester) async {
    await tester.pumpWidget(const PersonaOsApp());
    await tester.pump();
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
