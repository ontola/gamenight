import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// A whole-number setting: drag the slider, tap the value to type one, or
/// nudge it with − and +. Only a finished drag or a typed value is sent, so
/// dragging does not flood the room.
class NumberSetting extends StatefulWidget {
  /// The label row (with any "Saving…" note).
  final Widget title;

  /// For tooltips and the typing dialog.
  final String label;
  final Widget? subtitle;
  final int value;
  final int? min;
  final int? max;
  final ValueChanged<int> onChanged;

  const NumberSetting(
      {super.key,
      required this.title,
      required this.label,
      required this.value,
      required this.onChanged,
      this.subtitle,
      this.min,
      this.max});

  /// Wide ranges (a percentage) move in fives; a typed value is kept exact.
  static int stepFor(int? min, int? max) =>
      min != null && max != null && max - min > 50 ? 5 : 1;

  @override
  State<NumberSetting> createState() => _NumberSettingState();
}

class _NumberSettingState extends State<NumberSetting> {
  double? _dragging;

  /// What a tap just sent, until the next build shows it: taps quicker
  /// than a frame keep counting.
  int? _sent;

  int get _value => _sent ?? widget.value;

  int get _step => NumberSetting.stepFor(widget.min, widget.max);

  int _clamp(int v) {
    if (widget.min != null && v < widget.min!) return widget.min!;
    if (widget.max != null && v > widget.max!) return widget.max!;
    return v;
  }

  /// The next value a nudge lands on, snapped to the step; null at the end.
  int? _nudge(int direction) {
    final value = _value;
    final base = widget.min ?? 0;
    final off = (value - base) % _step;
    final v = _clamp(
        direction > 0 ? value + _step - off : value - (off == 0 ? _step : off));
    return v == value ? null : v;
  }

  void _set(int v) {
    v = _clamp(v);
    if (v == _value) return;
    _sent = v;
    widget.onChanged(v);
  }

  Future<void> _type() async {
    final typed = await showDialog<int>(
        context: context,
        builder: (context) => _TypeNumberDialog(
            label: widget.label,
            value: widget.value,
            min: widget.min,
            max: widget.max));
    if (typed != null && mounted) _set(typed);
  }

  @override
  Widget build(BuildContext context) {
    _sent = null;
    final min = widget.min, max = widget.max;
    final shown = _dragging?.round() ?? widget.value;
    final lower = _nudge(-1), higher = _nudge(1);
    final slider = min != null && max != null && max > min;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: widget.title),
          IconButton(
            tooltip: 'Less ${widget.label}',
            visualDensity: VisualDensity.compact,
            onPressed: lower == null ? null : () => _set(_nudge(-1) ?? _value),
            icon: const Icon(Icons.remove_circle_outline),
          ),
          Tooltip(
            message: 'Type a value',
            child: InkWell(
              key: const ValueKey('number-value'),
              borderRadius: BorderRadius.circular(8),
              onTap: _type,
              child: Container(
                constraints: const BoxConstraints(minWidth: 52),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: GnColors.field,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: GnColors.border),
                ),
                child: Text('$shown',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        fontFeatures: [FontFeature.tabularFigures()])),
              ),
            ),
          ),
          IconButton(
            tooltip: 'More ${widget.label}',
            visualDensity: VisualDensity.compact,
            onPressed: higher == null ? null : () => _set(_nudge(1) ?? _value),
            icon: const Icon(Icons.add_circle_outline),
          ),
        ]),
        if (widget.subtitle case final subtitle?) subtitle,
        if (slider)
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 6,
              showValueIndicator: ShowValueIndicator.never,
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 22),
            ),
            child: Slider(
              key: const ValueKey('number-slider'),
              min: min.toDouble(),
              max: max.toDouble(),
              divisions: ((max - min) / _step).ceil(),
              value: (_dragging ?? widget.value.toDouble())
                  .clamp(min.toDouble(), max.toDouble()),
              semanticFormatterCallback: (v) => '${v.round()}',
              onChanged: (v) => setState(() => _dragging = v),
              onChangeEnd: (v) {
                setState(() => _dragging = null);
                _set(v.round());
              },
            ),
          ),
      ]),
    );
  }
}

class _TypeNumberDialog extends StatefulWidget {
  final String label;
  final int value;
  final int? min;
  final int? max;
  const _TypeNumberDialog(
      {required this.label, required this.value, this.min, this.max});

  @override
  State<_TypeNumberDialog> createState() => _TypeNumberDialogState();
}

class _TypeNumberDialogState extends State<_TypeNumberDialog> {
  late final _field = TextEditingController(text: '${widget.value}')
    ..selection =
        TextSelection(baseOffset: 0, extentOffset: '${widget.value}'.length);
  String? _error;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  String get _range => switch ((widget.min, widget.max)) {
        (final lo?, final hi?) => '$lo to $hi',
        (final lo?, null) => 'at least $lo',
        (null, final hi?) => 'at most $hi',
        _ => 'a whole number',
      };

  void _submit() {
    final v = int.tryParse(_field.text.trim());
    if (v == null ||
        (widget.min != null && v < widget.min!) ||
        (widget.max != null && v > widget.max!)) {
      setState(() => _error = 'Choose $_range.');
      return;
    }
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) {
    final negative = widget.min == null || widget.min! < 0;
    return AlertDialog(
      title: Text(widget.label),
      content: TextField(
        key: const ValueKey('number-field'),
        controller: _field,
        autofocus: true,
        keyboardType: TextInputType.numberWithOptions(signed: negative),
        inputFormatters: [
          FilteringTextInputFormatter.allow(
              RegExp(negative ? r'-?\d*' : r'\d*'))
        ],
        textInputAction: TextInputAction.done,
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _submit(),
        decoration: InputDecoration(helperText: _range, errorText: _error),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
            key: const ValueKey('number-set'),
            onPressed: _submit,
            child: const Text('Set')),
      ],
    );
  }
}
