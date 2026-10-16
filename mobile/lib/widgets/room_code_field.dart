import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme.dart';

/// One accessible, pasteable text field, drawn as six fixed character slots.
class RoomCodeField extends StatefulWidget {
  final TextEditingController controller;
  final ValueChanged<String>? onChanged;
  final bool enabled;
  const RoomCodeField(
      {super.key,
      required this.controller,
      this.onChanged,
      this.enabled = true});
  @override
  State<RoomCodeField> createState() => _RoomCodeFieldState();
}

class _RoomCodeFieldState extends State<RoomCodeField>
    with SingleTickerProviderStateMixin {
  final _focus = FocusNode();
  late final _blink = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1000));
  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (_focus.hasFocus) {
        _blink.repeat();
      } else {
        _blink.stop();
      }
    });
  }

  @override
  void dispose() {
    _blink.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: LayoutBuilder(builder: (context, box) {
              const gap = 8.0;
              final cell = (box.maxWidth - gap * 5) / 6;
              const style = TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  fontFamily: 'monospace');
              final painter = TextPainter(
                  text: const TextSpan(text: 'W', style: style),
                  textDirection: TextDirection.ltr,
                  textScaler: MediaQuery.textScalerOf(context))
                ..layout();
              final characterWidth = painter.width;
              painter.dispose();
              return SizedBox(
                  height: 64,
                  child: Stack(children: [
                    Positioned.fill(
                        child: TextField(
                      controller: widget.controller,
                      focusNode: _focus,
                      enabled: widget.enabled,
                      autocorrect: false,
                      enableSuggestions: false,
                      textCapitalization: TextCapitalization.characters,
                      textDirection: TextDirection.ltr,
                      textAlign: TextAlign.left,
                      maxLength: 6,
                      showCursor: false,
                      style: style.copyWith(
                          color: Colors.transparent,
                          letterSpacing:
                              (cell + gap - characterWidth).clamp(0, 100)),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                            RegExp('[A-Za-z2-9]')),
                        TextInputFormatter.withFunction((_, value) =>
                            value.copyWith(text: value.text.toUpperCase()))
                      ],
                      decoration: const InputDecoration(
                          counterText: '',
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                          contentPadding:
                              EdgeInsets.only(left: 4, top: 16, bottom: 16)),
                      onChanged: widget.onChanged,
                    )),
                    Positioned.fill(
                        child: IgnorePointer(
                            child: ExcludeSemantics(
                                child: AnimatedBuilder(
                      animation:
                          Listenable.merge([widget.controller, _focus, _blink]),
                      builder: (context, _) {
                        final text = widget.controller.text;
                        final cursor = widget.controller.selection.extentOffset
                            .clamp(0, 5);
                        return Row(children: [
                          for (var i = 0; i < 6; i++) ...[
                            if (i > 0) const SizedBox(width: gap),
                            Expanded(
                                child: Container(
                              key: ValueKey('room-code-slot-$i'),
                              decoration: BoxDecoration(
                                  color: GnColors.field,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                      color: widget.enabled &&
                                              _focus.hasFocus &&
                                              cursor == i
                                          ? GnColors.accent
                                          : GnColors.border,
                                      width: _focus.hasFocus && cursor == i
                                          ? 2
                                          : 1)),
                              child: Center(
                                  child: Stack(
                                      alignment: Alignment.center,
                                      children: [
                                    Text(i < text.length ? text[i] : '',
                                        style: style),
                                    if (_focus.hasFocus &&
                                        cursor == i &&
                                        _blink.value < .5)
                                      Transform.translate(
                                          offset: Offset(
                                              i < text.length
                                                  ? (widget.controller.selection
                                                              .extentOffset <
                                                          text.length
                                                      ? -13
                                                      : 13)
                                                  : 0,
                                              0),
                                          child: Container(
                                              key: const ValueKey(
                                                  'room-code-cursor'),
                                              width: 2,
                                              height: 26,
                                              color: GnColors.accent)),
                                  ])),
                            )),
                          ]
                        ]);
                      },
                    )))),
                  ]));
            })),
      );
}
