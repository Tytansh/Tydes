/// A coarse, dated model outlook, never observed breaking-wave heights.
/// This deliberately cannot carry hourly, swell or tide data.
class BasicForecastModel {
  const BasicForecastModel({
    required this.spotId,
    required this.available,
    this.source = 'unavailable',
    this.marineModel,
    this.weatherModel,
    this.timezone,
    this.utcOffsetSeconds,
    this.fetchedAt,
    this.localDate,
    this.note,
    this.days = const [],
  });

  final String spotId;
  final bool available;
  final String source;
  final String? marineModel;
  final String? weatherModel;
  final String? timezone;
  final int? utcOffsetSeconds;
  final DateTime? fetchedAt;
  final String? localDate;
  final String? note;
  final List<BasicForecastDayModel> days;

  factory BasicForecastModel.unavailable(String spotId, {String? note}) =>
      BasicForecastModel(
        spotId: spotId,
        available: false,
        note:
            note ?? 'The basic daily outlook is unavailable. Please try again.',
      );

  /// Do not retain or display a previous local day's outlook as today's data.
  bool isCurrentAt(DateTime instant) {
    final stamp = fetchedAt;
    final offset = utcOffsetSeconds;
    if (!available ||
        source != 'open-meteo' ||
        stamp == null ||
        offset == null ||
        marineModel?.trim().isNotEmpty != true ||
        timezone?.trim().isNotEmpty != true ||
        offset < -14 * 3600 ||
        offset > 14 * 3600 ||
        days.isEmpty ||
        days.length > 5) {
      return false;
    }
    final now = instant.toUtc();
    final local = now.add(Duration(seconds: offset));
    final lastDay = basicForecastDateKey(
      DateTime.utc(local.year, local.month, local.day + 4),
    );
    return !stamp.isAfter(now.add(const Duration(minutes: 1))) &&
        !stamp.isBefore(now.subtract(const Duration(hours: 24))) &&
        localDate == basicForecastDateKey(local) &&
        days.every(
          (day) =>
              day.day.compareTo(localDate!) >= 0 &&
              day.day.compareTo(lastDay) <= 0 &&
              day.waveHeightM.isFinite &&
              day.waveHeightM >= 0,
        );
  }

  factory BasicForecastModel.fromJson(Map<String, dynamic> json) {
    final id = _requiredText(json['spot_id'], 'spot_id');
    final available = json['available'];
    final source = json['source'];
    if (available is! bool ||
        (source != 'open-meteo' && source != 'unavailable')) {
      throw const FormatException('The basic forecast source was incomplete.');
    }
    final localDate = _validDate(json['local_date']);
    final lastDay = basicForecastDateKey(
      DateTime.parse('${localDate}T00:00:00Z').add(const Duration(days: 4)),
    );
    final rawDays = json['days'];
    if (rawDays is! List || rawDays.length > 5) {
      throw const FormatException('The basic forecast days were incomplete.');
    }
    final days = <BasicForecastDayModel>[];
    String? previous;
    for (final raw in rawDays) {
      if (raw is! Map<String, dynamic>) {
        throw const FormatException('A basic forecast day was incomplete.');
      }
      final day = BasicForecastDayModel.fromJson(raw);
      if (day.day.compareTo(localDate) < 0 ||
          day.day.compareTo(lastDay) > 0 ||
          (previous != null && day.day.compareTo(previous) <= 0)) {
        throw const FormatException(
          'Basic forecast dates were not current or ordered.',
        );
      }
      previous = day.day;
      days.add(day);
    }
    final model = _optionalText(json['marine_model']);
    final timezone = _optionalText(json['timezone']);
    final offset = json['utc_offset_seconds'];
    if (offset != null &&
        (offset is! int || offset < -14 * 3600 || offset > 14 * 3600)) {
      throw const FormatException('The basic forecast time zone was invalid.');
    }
    final rawStamp = json['fetched_at'];
    final stamp = rawStamp is String ? DateTime.tryParse(rawStamp) : null;
    if (rawStamp != null && (stamp == null || !stamp.isUtc)) {
      throw const FormatException(
        'The basic forecast retrieval time was invalid.',
      );
    }
    if (available &&
        (source != 'open-meteo' ||
            model == null ||
            timezone == null ||
            offset == null ||
            stamp == null ||
            days.isEmpty)) {
      throw const FormatException(
        'The basic forecast provenance was incomplete.',
      );
    }
    if (!available && days.isNotEmpty) {
      throw const FormatException(
        'Unavailable forecasts cannot contain readings.',
      );
    }
    return BasicForecastModel(
      spotId: id,
      available: available,
      source: source as String,
      marineModel: model,
      weatherModel: switch (json['weather_model']) {
        'Best Match (automatic)' => 'Best Match (automatic)',
        'Temporarily unavailable' => 'Temporarily unavailable',
        _ => null,
      },
      timezone: timezone,
      utcOffsetSeconds: offset as int?,
      fetchedAt: stamp?.toUtc(),
      localDate: localDate,
      note: _optionalText(json['note']),
      days: List.unmodifiable(days),
    );
  }
}

class BasicForecastDayModel {
  const BasicForecastDayModel({
    required this.day,
    required this.waveHeightM,
    this.windKts,
    this.windDirectionDeg,
    this.windDirectionStatus = 'unavailable',
    this.seaSurfaceTemperatureC,
    this.sunriseLocal,
    this.sunsetLocal,
  });

  final String day;
  final double waveHeightM;
  final double? windKts;
  final int? windDirectionDeg;
  final String windDirectionStatus;
  final double? seaSurfaceTemperatureC;
  final String? sunriseLocal;
  final String? sunsetLocal;

  factory BasicForecastDayModel.fromJson(Map<String, dynamic> json) {
    final height = json['wave_height_m'];
    if (height is! num || !height.toDouble().isFinite || height < 0) {
      throw const FormatException('The daily wave height was invalid.');
    }
    final wind = _optionalNumber(json['wind_kts'], min: 0, max: 250);
    final rawDirection = json['wind_direction_deg'];
    int? direction =
        rawDirection is int && rawDirection >= 0 && rawDirection <= 359
        ? rawDirection
        : null;
    var status = switch (json['wind_direction_status']) {
      'available' => 'available',
      'variable' => 'variable',
      'calm' => 'calm',
      _ => 'unavailable',
    };
    if (wind == null ||
        (status == 'available' && (direction == null || wind < 1)) ||
        (status == 'calm' && wind >= 1) ||
        (status == 'variable' && wind < 1)) {
      status = 'unavailable';
    }
    if (status != 'available') direction = null;
    var sunrise = _localTime(json['sunrise_local']);
    var sunset = _localTime(json['sunset_local']);
    if (sunrise != null && sunset != null && sunrise.compareTo(sunset) >= 0) {
      sunrise = null;
      sunset = null;
    }
    return BasicForecastDayModel(
      day: _validDate(json['day']),
      waveHeightM: height.toDouble(),
      windKts: wind,
      windDirectionDeg: direction,
      windDirectionStatus: status,
      seaSurfaceTemperatureC: _optionalNumber(
        json['sea_surface_temperature_c'],
        min: -5,
        max: 50,
      ),
      sunriseLocal: sunrise,
      sunsetLocal: sunset,
    );
  }
}

double? _optionalNumber(
  Object? value, {
  required double min,
  required double max,
}) => value is num && value.toDouble().isFinite && value >= min && value <= max
    ? value.toDouble()
    : null;

String? _localTime(Object? value) =>
    value is String && RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d$').hasMatch(value)
    ? value
    : null;

String basicForecastDateKey(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

String _validDate(Object? value) {
  final date = value is String ? DateTime.tryParse(value) : null;
  if (value is! String ||
      !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value) ||
      date == null ||
      basicForecastDateKey(date) != value) {
    throw const FormatException('The basic forecast date was invalid.');
  }
  return value;
}

String? _optionalText(Object? value) {
  if (value == null) return null;
  if (value is! String || value.trim().isEmpty) return null;
  return value.trim();
}

String _requiredText(Object? value, String label) {
  final text = _optionalText(value);
  if (text == null) {
    throw FormatException('The forecast $label was incomplete.');
  }
  return text;
}
