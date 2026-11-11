/// Model forecasts, not observed or calibrated breaking-wave heights.
class DetailedForecastModel {
  const DetailedForecastModel({
    required this.spotId,
    required this.available,
    this.source = 'open-meteo',
    this.marineModel,
    this.weatherModel,
    this.timezone,
    this.utcOffsetSeconds,
    this.fetchedAt,
    this.localDate,
    this.note,
    this.hours = const [],
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
  final List<HourlyForecastModel> hours;
  final List<ForecastDaylightModel> days;

  factory DetailedForecastModel.unavailable(String spotId, {String? note}) =>
      DetailedForecastModel(
        spotId: spotId,
        available: false,
        note: note ?? 'The detailed forecast is unavailable. Please try again.',
      );

  factory DetailedForecastModel.fromJson(Map<String, dynamic> json) =>
      DetailedForecastModel(
        spotId: json['spot_id'] as String,
        available: json['available'] == true,
        source: json['source'] as String? ?? 'open-meteo',
        marineModel: json['marine_model'] as String?,
        weatherModel: json['weather_model'] as String?,
        timezone: json['timezone'] as String?,
        utcOffsetSeconds: (json['utc_offset_seconds'] as num?)?.toInt(),
        fetchedAt: DateTime.tryParse(json['fetched_at'] as String? ?? ''),
        localDate: json['local_date'] as String?,
        note: json['note'] as String?,
        hours: (json['hours'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(HourlyForecastModel.fromJson)
            .where((hour) => DateTime.tryParse(hour.time) != null)
            .toList(growable: false),
        days: (json['days'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ForecastDaylightModel.fromJson)
            .toList(growable: false),
      );
}

class HourlyForecastModel {
  const HourlyForecastModel({
    required this.time,
    required this.localDate,
    required this.localTime,
    this.isDay,
    this.waveHeightM,
    this.wavePeriodS,
    this.waveDirectionDeg,
    this.swellHeightM,
    this.swellPeriodS,
    this.swellPeakPeriodS,
    this.swellDirectionDeg,
    this.secondarySwellHeightM,
    this.secondarySwellPeriodS,
    this.secondarySwellDirectionDeg,
    this.windWaveHeightM,
    this.windWavePeriodS,
    this.windWaveDirectionDeg,
    this.windKts,
    this.windGustsKts,
    this.windDirectionDeg,
    this.seaSurfaceTemperatureC,
  });

  final String time;
  final String localDate;
  final String localTime;
  final bool? isDay;
  final double? waveHeightM;
  final double? wavePeriodS;
  final double? waveDirectionDeg;
  final double? swellHeightM;
  final double? swellPeriodS;
  final double? swellPeakPeriodS;
  final double? swellDirectionDeg;
  final double? secondarySwellHeightM;
  final double? secondarySwellPeriodS;
  final double? secondarySwellDirectionDeg;
  final double? windWaveHeightM;
  final double? windWavePeriodS;
  final double? windWaveDirectionDeg;
  final double? windKts;
  final double? windGustsKts;
  final double? windDirectionDeg;
  final double? seaSurfaceTemperatureC;

  factory HourlyForecastModel.fromJson(Map<String, dynamic> json) =>
      HourlyForecastModel(
        time: json['time'] as String? ?? '',
        localDate: json['local_date'] as String? ?? '',
        localTime: json['local_time'] as String? ?? '',
        isDay: json['is_day'] as bool?,
        waveHeightM: _finite(json['wave_height_m']),
        wavePeriodS: _finite(json['wave_period_s']),
        waveDirectionDeg: _finite(json['wave_direction_deg']),
        swellHeightM: _finite(json['swell_height_m']),
        swellPeriodS: _finite(json['swell_period_s']),
        swellPeakPeriodS: _finite(json['swell_peak_period_s']),
        swellDirectionDeg: _finite(json['swell_direction_deg']),
        secondarySwellHeightM: _finite(json['secondary_swell_height_m']),
        secondarySwellPeriodS: _finite(json['secondary_swell_period_s']),
        secondarySwellDirectionDeg: _finite(
          json['secondary_swell_direction_deg'],
        ),
        windWaveHeightM: _finite(json['wind_wave_height_m']),
        windWavePeriodS: _finite(json['wind_wave_period_s']),
        windWaveDirectionDeg: _finite(json['wind_wave_direction_deg']),
        windKts: _finite(json['wind_kts']),
        windGustsKts: _finite(json['wind_gusts_kts']),
        windDirectionDeg: _finite(json['wind_direction_deg']),
        seaSurfaceTemperatureC: _finite(json['sea_surface_temperature_c']),
      );
}

class ForecastDaylightModel {
  const ForecastDaylightModel({required this.day, this.sunrise, this.sunset});

  final String day;
  final String? sunrise;
  final String? sunset;

  factory ForecastDaylightModel.fromJson(Map<String, dynamic> json) =>
      ForecastDaylightModel(
        day: json['day'] as String,
        sunrise: json['sunrise'] as String?,
        sunset: json['sunset'] as String?,
      );
}

double? _finite(dynamic value) {
  if (value is! num) return null;
  final number = value.toDouble();
  return number.isFinite ? number : null;
}
