import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'theme_preference.dart';

class AppearanceSettingsTile extends ConsumerWidget {
  const AppearanceSettingsTile({super.key, this.contentPadding});
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    return ListTile(
      key: const ValueKey('appearance-settings'),
      contentPadding: contentPadding,
      leading: Icon(switch (mode) {
        ThemeMode.dark => Icons.dark_mode_outlined,
        ThemeMode.light => Icons.light_mode_outlined,
        ThemeMode.system => Icons.brightness_auto_outlined,
      }),
      title: const Text('Appearance'),
      subtitle: Text('${themeModeLabel(mode)} · Light or dark on this device'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => showDialog<void>(
        context: context,
        builder: (_) => const AppearanceSettingsDialog(),
      ),
    );
  }
}

class AppearanceSettingsDialog extends ConsumerStatefulWidget {
  const AppearanceSettingsDialog({super.key});

  @override
  ConsumerState<AppearanceSettingsDialog> createState() =>
      _AppearanceSettingsDialogState();
}

class _AppearanceSettingsDialogState
    extends ConsumerState<AppearanceSettingsDialog> {
  bool _saving = false;
  String? _error;

  Future<void> _select(ThemeMode mode) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final saved = await ref.read(themeModeProvider.notifier).setMode(mode);
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (!saved) _error = 'Could not save appearance. Please try again.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(themeModeProvider);
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Appearance'),
      content: SizedBox(
        width: 340,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Choose your look. Saved on this device.'),
              const SizedBox(height: 16),
              for (final option in ThemeMode.values)
                ListTile(
                  key: ValueKey('appearance-${option.name}'),
                  contentPadding: EdgeInsets.zero,
                  enabled: !_saving,
                  selected: mode == option,
                  leading: Icon(switch (option) {
                    ThemeMode.system => Icons.brightness_auto_outlined,
                    ThemeMode.light => Icons.light_mode_outlined,
                    ThemeMode.dark => Icons.dark_mode_outlined,
                  }),
                  title: Text(themeModeLabel(option)),
                  subtitle: option == ThemeMode.system
                      ? const Text('Follow your phone or computer settings')
                      : null,
                  trailing: mode == option
                      ? Icon(Icons.check_circle, color: scheme.primary)
                      : const Icon(Icons.circle_outlined),
                  onTap: () => _select(option),
                ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: scheme.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
