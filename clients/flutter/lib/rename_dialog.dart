import 'package:flutter/material.dart';
import 'discard_on_back.dart';
import 'file_rename.dart';

class RenameDialog extends StatefulWidget {
  const RenameDialog(
      {super.key, required this.initialName, required this.isDir});
  final String initialName;
  final bool isDir;
  @override
  State<RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<RenameDialog> {
  late final _name = TextEditingController(text: widget.initialName);
  final _form = GlobalKey<FormState>();
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    if (_form.currentState!.validate()) Navigator.pop(context, _name.text);
  }

  @override
  Widget build(BuildContext context) => DiscardOnBack(
        hasUnsavedInput: () => _name.text != widget.initialName,
        child: AlertDialog(
          title: Text(widget.isDir ? 'Rename folder' : 'Rename file'),
          content: Form(
              key: _form,
              child: TextFormField(
                controller: _name,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'New name'),
                validator: (name) => renameValidationError(name ?? ''),
                onFieldSubmitted: (_) => _submit(),
              )),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel')),
            FilledButton(onPressed: _submit, child: const Text('Rename')),
          ],
        ),
      );
}
