import 'package:flutter/material.dart';

/// Keeps Android system back from throwing away typed input without a word.
///
/// Dialogs close on back. When the field still holds text the user meant to
/// keep, ask first; otherwise back just closes the dialog. Buttons keep popping
/// directly, so Cancel and the primary action behave as before.
class DiscardOnBack extends StatelessWidget {
  const DiscardOnBack({
    super.key,
    required this.hasUnsavedInput,
    required this.child,
  });

  /// Evaluated when back arrives, so it follows the field's current contents.
  final bool Function() hasUnsavedInput;
  final Widget child;

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, Object? result) async {
          if (didPop) return;
          final navigator = Navigator.of(context);
          if (!hasUnsavedInput()) {
            navigator.pop();
            return;
          }
          final discard = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Discard your text?'),
              content: const Text('What you typed has not been saved.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Keep editing')),
                TextButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Discard')),
              ],
            ),
          );
          if (discard == true && navigator.mounted) navigator.pop();
        },
        child: child,
      );
}
