import 'package:flutter/widgets.dart';
import 'reports.dart';

class ReportScope extends InheritedWidget {
  const ReportScope({super.key, required this.reports, required super.child});
  final ReportService? reports;
  static ReportService? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ReportScope>()?.reports;
  @override
  bool updateShouldNotify(ReportScope oldWidget) => reports != oldWidget.reports;
}
