import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';

final alertsProvider =
    AsyncNotifierProvider<AlertsController, List<AlertModel>>(
      AlertsController.new,
    );

/// Only server-confirmed results change the displayed alert list.
class AlertsController extends AsyncNotifier<List<AlertModel>> {
  int _generation = 0;
  bool _disposed = false;

  @override
  Future<List<AlertModel>> build() {
    _generation++;
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    ref.watch(alertsRefreshKeyProvider);
    return ref.watch(surfRepositoryProvider).fetchAlerts();
  }

  Future<int> _prepare() async {
    if (state.hasError && !state.isLoading) ref.invalidateSelf();
    final loaded = future; // Flush an explicitly requested retry first.
    final generation = _generation;
    await loaded;
    _checkGeneration(generation);
    return generation;
  }

  void _checkGeneration(int generation) {
    if (_disposed || generation != _generation) {
      throw StateError(
        'Your account changed. Refresh your alerts and try again.',
      );
    }
  }

  void _accept(AlertModel alert, int generation) {
    _checkGeneration(generation);
    final items = state.valueOrNull ?? const <AlertModel>[];
    state = AsyncData(
      items.any((item) => item.id == alert.id)
          ? [for (final item in items) item.id == alert.id ? alert : item]
          : [alert, ...items],
    );
  }

  Future<AlertModel> save({
    String? alertId,
    required String spotId,
    required bool waveEnabled,
    double? minWaveHeightM,
    required bool windEnabled,
    int? maxWindKts,
    required bool tideEnabled,
    String? tideType,
    int? tideOffsetHours,
    bool enabled = true,
  }) async {
    final generation = await _prepare();
    final repository = ref.read(surfRepositoryProvider);
    final saved = alertId == null
        ? await repository.createAlert(
            spotId: spotId,
            waveEnabled: waveEnabled,
            minWaveHeightM: minWaveHeightM,
            windEnabled: windEnabled,
            maxWindKts: maxWindKts,
            tideEnabled: tideEnabled,
            tideType: tideType,
            tideOffsetHours: tideOffsetHours,
            enabled: enabled,
          )
        : await repository.updateAlert(
            alertId: alertId,
            spotId: spotId,
            waveEnabled: waveEnabled,
            minWaveHeightM: minWaveHeightM,
            windEnabled: windEnabled,
            maxWindKts: maxWindKts,
            tideEnabled: tideEnabled,
            tideType: tideType,
            tideOffsetHours: tideOffsetHours,
            enabled: enabled,
          );
    _accept(saved, generation);
    return saved;
  }

  Future<void> setEnabled(String alertId, bool enabled) async {
    final generation = await _prepare();
    final saved = await ref
        .read(surfRepositoryProvider)
        .updateAlertEnabled(alertId: alertId, enabled: enabled);
    _accept(saved, generation);
  }

  Future<void> delete(String alertId) async {
    final generation = await _prepare();
    await ref.read(surfRepositoryProvider).deleteAlert(alertId);
    _checkGeneration(generation);
    state = AsyncData([
      ...?state.valueOrNull?.where((item) => item.id != alertId),
    ]);
  }
}
