import 'package:flutter/material.dart';

/// One of a fixed set of options: a row of chips when there are a few, a
/// dropdown when there are more (a dozen modifiers do not fit as chips).
class ChoiceSetting extends StatelessWidget {
  /// The label row (with any "Saving…" note).
  final Widget title;
  final Widget? subtitle;
  final List<String> options;
  final String value;
  final ValueChanged<String> onChanged;

  /// More options than this become a dropdown.
  static const maxChips = 4;

  const ChoiceSetting(
      {super.key,
      required this.title,
      required this.options,
      required this.value,
      required this.onChanged,
      this.subtitle});

  void _pick(String? option) {
    if (option != null && option != value) onChanged(option);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        title,
        if (subtitle case final subtitle?) subtitle,
        const SizedBox(height: 8),
        if (options.length > maxChips)
          DropdownButtonFormField<String>(
            // A form field keeps its first value: a new one (the game reset
            // it) builds it again.
            key: ValueKey('choice-dropdown-$value'),
            initialValue: options.contains(value) ? value : null,
            isExpanded: true,
            items: [
              for (final option in options)
                DropdownMenuItem(value: option, child: Text(option)),
            ],
            onChanged: _pick,
          )
        else
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final option in options)
              ChoiceChip(
                label: Text(option),
                selected: option == value,
                onSelected: (_) => _pick(option),
              ),
          ]),
      ]),
    );
  }
}
