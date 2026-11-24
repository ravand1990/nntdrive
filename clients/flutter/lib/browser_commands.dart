import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Browser-level adapters only. Item/selection operations deliberately do not
/// belong to this bounded registry until a listing-scoped selection model exists.
class BrowserCommand {
  const BrowserCommand(
    this.id,
    this.label, {
    this.binding = '',
    this.disabledReason,
  });
  final String id;
  final String label;
  final String binding;
  final String? disabledReason;
}

class BrowserCommandIntent extends Intent {
  const BrowserCommandIntent(this.id);
  final String id;
}

/// Reject before Shortcuts consumes a key: returning a disabled Action alone
/// would still steal editing keys from the focused native/text control.
class BrowserKeyActivator extends SingleActivator {
  const BrowserKeyActivator(
    super.trigger, {
    required this.admit,
    super.control,
    super.meta,
    super.shift,
    super.alt,
  }) : super(includeRepeats: false);
  final bool Function() admit;

  @override
  bool accepts(KeyEvent event, HardwareKeyboard state) =>
      admit() && super.accepts(event, state);
}

class BrowserCommandPalette extends StatefulWidget {
  const BrowserCommandPalette({
    super.key,
    required this.commands,
    this.help = false,
  });
  final List<BrowserCommand> commands;
  final bool help;

  @override
  State<BrowserCommandPalette> createState() => _BrowserCommandPaletteState();
}

class _BrowserCommandPaletteState extends State<BrowserCommandPalette> {
  final _query = TextEditingController();
  late final _focus = FocusNode(onKeyEvent: _key);
  final _rowKeys = <String, GlobalKey>{};
  int _selected = 0;

  List<BrowserCommand> get _visible => widget.commands
      .where(
        (command) => '${command.label} ${command.binding}'
            .toLowerCase()
            .contains(_query.text.toLowerCase().trim()),
      )
      .toList();

  void _choose(BrowserCommand command) {
    if (command.disabledReason == null) Navigator.of(context).pop(command.id);
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || !_query.value.composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    final rows = _visible;
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      if (rows.isNotEmpty) _choose(rows[_selected]);
      return KeyEventResult.handled;
    }
    final direction = event.logicalKey == LogicalKeyboardKey.arrowDown
        ? 1
        : event.logicalKey == LogicalKeyboardKey.arrowUp
        ? -1
        : 0;
    if (direction == 0 || rows.isEmpty) return KeyEventResult.ignored;
    setState(() => _selected = (_selected + direction) % rows.length);
    final selectedId = rows[_selected].id;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final rowContext = _rowKeys[selectedId]?.currentContext;
      if (mounted && rowContext != null) Scrollable.ensureVisible(rowContext);
    });
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _focus.dispose();
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rows = _visible;
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.help ? 'Browser shortcuts' : 'Browser commands',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                if (!widget.help)
                  TextField(
                    controller: _query,
                    focusNode: _focus,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Search commands',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() => _selected = 0),
                  ),
                const SizedBox(height: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!widget.help && rows.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('No matching commands'),
                      ),
                    for (var i = 0; i < rows.length; i++)
                      KeyedSubtree(
                        key: _rowKeys.putIfAbsent(
                          rows[i].id,
                          () => GlobalKey(),
                        ),
                        child: ListTile(
                          key: ValueKey('command-${rows[i].id}'),
                          minTileHeight: 48,
                          selected: !widget.help && i == _selected,
                          enabled: rows[i].disabledReason == null,
                          title: Text(rows[i].label),
                          subtitle: Text(
                            [
                              if (rows[i].binding.isNotEmpty) rows[i].binding,
                              if (rows[i].disabledReason != null)
                                rows[i].disabledReason!,
                            ].join(' · '),
                          ),
                          onTap: widget.help ? null : () => _choose(rows[i]),
                        ),
                      ),
                    if (widget.help)
                      const Padding(
                        padding: EdgeInsets.all(8),
                        child: Text(
                          'Shortcuts apply only in the ready, uncovered browser, outside text editing and IME composition. '
                          'Ctrl and Cmd variants are accepted for K, /, F and Shift+F. '
                          'Selection commands are unfinished: item open, rename, delete, move, copy, select-all, clear selection and context-menu keys. '
                          'Breadcrumb/history Back and Forward shortcuts are also unfinished. No destructive shortcut is registered.',
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
