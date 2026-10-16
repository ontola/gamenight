import 'package:flutter/widgets.dart';
import 'reports.dart';

class ReportScope extends InheritedWidget {
  const ReportScope(
      {super.key,
      required this.reports,
      this.gameContext,
      required super.child});
  final ReportService? reports;
  final FeedbackGameContext? gameContext;
  static FeedbackGameContext? gameContextOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ReportScope>()?.gameContext;
  static ReportService? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ReportScope>()?.reports;
  @override
  bool updateShouldNotify(ReportScope oldWidget) =>
      reports != oldWidget.reports || gameContext != oldWidget.gameContext;
}

/// The visible game page supplies context to the persistent app feedback action.
/// Readers return null while their route is covered, so unrelated screens never
/// inherit a game from a page underneath them.
class FeedbackGameContext {
  final _readers = <Object, ValueGetter<String?>>{};
  void register(Object owner, ValueGetter<String?> read) =>
      _readers[owner] = read;
  void unregister(Object owner) => _readers.remove(owner);
  String? get game {
    String? visible;
    for (final read in _readers.values) {
      visible = read() ?? visible;
    }
    return visible;
  }
}
