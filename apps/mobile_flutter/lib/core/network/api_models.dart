class UserProfile {
  UserProfile({
    required this.id,
    required this.email,
    required this.displayName,
    required this.handle,
    required this.bio,
    required this.surfSkill,
    required this.avatarUrl,
    required this.homeRegion,
    required this.locale,
    required this.premium,
    required this.freeLiveSpotId,
    required this.adsEnabled,
    required this.favoriteSpotIds,
  });

  final String id;
  final String email;
  final String displayName;
  final String handle;
  final String bio;
  final String surfSkill;
  final String? avatarUrl;
  final String homeRegion;
  final String locale;
  final bool premium;
  final String? freeLiveSpotId;
  final bool adsEnabled;
  final List<String> favoriteSpotIds;

  bool canAccessLiveForecast(String spotId) {
    return premium || freeLiveSpotId == spotId;
  }

  UserProfile copyWith({
    String? id,
    String? email,
    String? displayName,
    String? handle,
    String? bio,
    String? surfSkill,
    String? avatarUrl,
    String? homeRegion,
    String? locale,
    bool? premium,
    String? freeLiveSpotId,
    bool clearFreeLiveSpotId = false,
    bool? adsEnabled,
    List<String>? favoriteSpotIds,
  }) => UserProfile(
    id: id ?? this.id,
    email: email ?? this.email,
    displayName: displayName ?? this.displayName,
    handle: handle ?? this.handle,
    bio: bio ?? this.bio,
    surfSkill: surfSkill ?? this.surfSkill,
    avatarUrl: avatarUrl ?? this.avatarUrl,
    homeRegion: homeRegion ?? this.homeRegion,
    locale: locale ?? this.locale,
    premium: premium ?? this.premium,
    freeLiveSpotId: clearFreeLiveSpotId
        ? null
        : (freeLiveSpotId ?? this.freeLiveSpotId),
    adsEnabled: adsEnabled ?? this.adsEnabled,
    favoriteSpotIds: favoriteSpotIds ?? this.favoriteSpotIds,
  );

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
    id: json['id'] as String,
    email: json['email'] as String,
    displayName: json['display_name'] as String,
    handle: json['handle'] as String? ?? (json['email'] as String).split('@').first,
    bio:
        json['bio'] as String? ??
        'Looking for clean waves, easy travel days, and people to paddle out with.',
    surfSkill: json['surf_skill'] as String? ?? 'intermediate',
    avatarUrl: json['avatar_url'] as String?,
    homeRegion: json['home_region'] as String,
    locale: json['locale'] as String,
    premium: json['premium'] as bool? ?? false,
    freeLiveSpotId: json['free_live_spot_id'] as String?,
    adsEnabled: json['ads_enabled'] as bool? ?? true,
    favoriteSpotIds: List<String>.from(
      json['favorite_spot_ids'] as List<dynamic>? ?? const [],
    ),
  );
}

class SpotModel {
  SpotModel({
    required this.id,
    required this.name,
    required this.country,
    required this.region,
    required this.area,
    required this.latitude,
    required this.longitude,
    required this.difficulty,
    required this.bestMonths,
    required this.waveHeightM,
    required this.waterTempC,
    required this.imageUrl,
    required this.summary,
  });

  final String id;
  final String name;
  final String country;
  final String region;
  final String area;
  final double latitude;
  final double longitude;
  final String difficulty;
  final List<String> bestMonths;
  final double waveHeightM;
  final double waterTempC;
  final String imageUrl;
  final String summary;

  factory SpotModel.fromJson(Map<String, dynamic> json) => SpotModel(
    id: json['id'] as String,
    name: json['name'] as String,
    country: json['country'] as String,
    region: json['region'] as String,
    area: json['area'] as String? ?? json['region'] as String,
    latitude: (json['latitude'] as num).toDouble(),
    longitude: (json['longitude'] as num).toDouble(),
    difficulty: json['difficulty'] as String,
    bestMonths: List<String>.from(json['best_months'] as List<dynamic>),
    waveHeightM: (json['wave_height_m'] as num).toDouble(),
    waterTempC: (json['water_temp_c'] as num).toDouble(),
    imageUrl: json['image_url'] as String,
    summary: json['summary'] as String,
  );
}

class ForecastModel {
  ForecastModel({
    required this.id,
    required this.spotId,
    required this.day,
    required this.waveHeightM,
    required this.waveHeightMinM,
    required this.waveHeightMaxM,
    required this.periodS,
    required this.windKts,
    required this.windKtsMin,
    required this.windKtsMax,
    required this.quality,
    required this.swellWaveHeightM,
    required this.windWaveHeightM,
    required this.seaSurfaceTemperatureC,
    required this.source,
    required this.confidence,
    required this.confidenceNote,
  });

  final String id;
  final String spotId;
  final String day;
  final double? waveHeightM;
  final double? waveHeightMinM;
  final double? waveHeightMaxM;
  final int? periodS;
  final double? windKts;
  final double? windKtsMin;
  final double? windKtsMax;
  final String quality;
  final double? swellWaveHeightM;
  final double? windWaveHeightM;
  final double? seaSurfaceTemperatureC;
  final String source;
  final String confidence;
  final String? confidenceNote;

  bool get isLive => confidence == 'live';

  String get waveDisplay {
    if (waveHeightMinM != null && waveHeightMaxM != null) {
      return '${_formatDecimal(waveHeightMinM!)}-${_formatDecimal(waveHeightMaxM!)}m';
    }
    if (waveHeightM != null) {
      return '${_formatDecimal(waveHeightM!)}m';
    }
    return 'Unavailable';
  }

  String? get windDisplay {
    if (windKtsMin != null && windKtsMax != null) {
      return '${_formatDecimal(windKtsMin!)}-${_formatDecimal(windKtsMax!)}kts';
    }
    if (windKts != null) {
      return '${_formatDecimal(windKts!)}kts';
    }
    return null;
  }

  factory ForecastModel.fromJson(Map<String, dynamic> json) => ForecastModel(
    id: json['id'] as String,
    spotId: json['spot_id'] as String,
    day: json['day'] as String,
    waveHeightM: (json['wave_height_m'] as num?)?.toDouble(),
    waveHeightMinM: (json['wave_height_min_m'] as num?)?.toDouble(),
    waveHeightMaxM: (json['wave_height_max_m'] as num?)?.toDouble(),
    periodS: json['period_s'] as int?,
    windKts: (json['wind_kts'] as num?)?.toDouble(),
    windKtsMin: (json['wind_kts_min'] as num?)?.toDouble(),
    windKtsMax: (json['wind_kts_max'] as num?)?.toDouble(),
    quality: json['quality'] as String,
    swellWaveHeightM: (json['swell_wave_height_m'] as num?)?.toDouble(),
    windWaveHeightM: (json['wind_wave_height_m'] as num?)?.toDouble(),
    seaSurfaceTemperatureC: (json['sea_surface_temperature_c'] as num?)
        ?.toDouble(),
    source: json['source'] as String? ?? 'seed',
    confidence: json['confidence'] as String? ?? 'estimated',
    confidenceNote: json['confidence_note'] as String?,
  );
}

class TideForecastModel {
  TideForecastModel({
    required this.spotId,
    required this.available,
    required this.stationName,
    required this.stationDistanceKm,
    required this.source,
    required this.events,
    required this.note,
  });

  final String spotId;
  final bool available;
  final String? stationName;
  final double? stationDistanceKm;
  final String source;
  final List<TideEventModel> events;
  final String? note;

  factory TideForecastModel.unavailable(String spotId) => TideForecastModel(
    spotId: spotId,
    available: false,
    stationName: null,
    stationDistanceKm: null,
    source: 'unavailable',
    events: const [],
    note: 'Tide data is unavailable right now.',
  );

  factory TideForecastModel.fromJson(Map<String, dynamic> json) =>
      TideForecastModel(
        spotId: json['spot_id'] as String,
        available: json['available'] as bool? ?? false,
        stationName: json['station_name'] as String?,
        stationDistanceKm: (json['station_distance_km'] as num?)?.toDouble(),
        source: json['source'] as String? ?? 'unavailable',
        events: (json['events'] as List<dynamic>? ?? const [])
            .map(
              (item) => TideEventModel.fromJson(item as Map<String, dynamic>),
            )
            .toList(),
        note: json['note'] as String?,
      );
}

class TideEventModel {
  TideEventModel({
    required this.type,
    required this.time,
    required this.localTime,
    required this.localDate,
    required this.heightM,
  });

  final String type;
  final String time;
  final String localTime;
  final String localDate;
  final double? heightM;

  String get label => type == 'high' ? 'High' : 'Low';

  String get heightDisplay =>
      heightM == null ? '' : ' • ${_formatDecimal(heightM!)}m';

  factory TideEventModel.fromJson(Map<String, dynamic> json) => TideEventModel(
    type: json['type'] as String,
    time: json['time'] as String,
    localTime: json['local_time'] as String,
    localDate: json['local_date'] as String,
    heightM: (json['height_m'] as num?)?.toDouble(),
  );
}

String _formatDecimal(double value) {
  final rounded = value.toStringAsFixed(1);
  return rounded.endsWith('.0')
      ? rounded.substring(0, rounded.length - 2)
      : rounded;
}

class TripModel {
  TripModel({
    required this.id,
    required this.title,
    required this.destination,
    required this.startDate,
    required this.endDate,
    required this.travelers,
    required this.notes,
    required this.budgetUsd,
  });

  final String id;
  final String title;
  final String destination;
  final String startDate;
  final String endDate;
  final int travelers;
  final String notes;
  final int budgetUsd;

  factory TripModel.fromJson(Map<String, dynamic> json) => TripModel(
    id: json['id'] as String,
    title: json['title'] as String,
    destination: json['destination'] as String,
    startDate: json['start_date'] as String,
    endDate: json['end_date'] as String,
    travelers: json['travelers'] as int? ?? 1,
    notes: json['notes'] as String? ?? '',
    budgetUsd: json['budget_usd'] as int? ?? 0,
  );
}

class AlertModel {
  AlertModel({
    required this.id,
    required this.spotId,
    required this.waveEnabled,
    required this.minWaveHeightM,
    required this.windEnabled,
    required this.maxWindKts,
    required this.tideEnabled,
    required this.tideType,
    required this.tideOffsetHours,
    required this.enabled,
    this.status = 'watching',
    this.statusReason,
    this.lastEvaluatedAt,
    this.lastTriggeredAt,
    required this.nextCheckAt,
  });

  final String id;
  final String spotId;
  final bool waveEnabled;
  final double? minWaveHeightM;
  final bool windEnabled;
  final int? maxWindKts;
  final bool tideEnabled;
  final String? tideType;
  final int? tideOffsetHours;
  final bool enabled;
  final String status;
  final String? statusReason;
  final String? lastEvaluatedAt;
  final String? lastTriggeredAt;
  final String nextCheckAt;

  factory AlertModel.fromJson(Map<String, dynamic> json) => AlertModel(
    id: json['id'] as String,
    spotId: json['spot_id'] as String,
    waveEnabled: json['wave_enabled'] as bool? ?? true,
    minWaveHeightM: (json['min_wave_height_m'] as num?)?.toDouble(),
    windEnabled: json['wind_enabled'] as bool? ?? true,
    maxWindKts: json['max_wind_kts'] as int?,
    tideEnabled: json['tide_enabled'] as bool? ?? false,
    tideType: json['tide_type'] as String?,
    tideOffsetHours: json['tide_offset_hours'] as int?,
    enabled: json['enabled'] as bool? ?? true,
    status: json['status'] as String? ?? 'watching',
    statusReason: json['status_reason'] as String?,
    lastEvaluatedAt: json['last_evaluated_at'] as String?,
    lastTriggeredAt: json['last_triggered_at'] as String?,
    nextCheckAt: json['next_check_at'] as String,
  );
}

class FriendProfileModel {
  FriendProfileModel({
    required this.id,
    required this.displayName,
    required this.homeRegion,
    required this.avatarEmoji,
    required this.vibe,
  });

  final String id;
  final String displayName;
  final String homeRegion;
  final String avatarEmoji;
  final String vibe;

  factory FriendProfileModel.fromJson(Map<String, dynamic> json) =>
      FriendProfileModel(
        id: json['id'] as String,
        displayName: json['display_name'] as String,
        homeRegion: json['home_region'] as String,
        avatarEmoji: json['avatar_emoji'] as String,
        vibe: json['vibe'] as String,
      );
}

class SocialPostModel {
  SocialPostModel({
    required this.id,
    required this.userId,
    required this.authorName,
    required this.authorHandle,
    required this.authorAvatarUrl,
    required this.authorPremium,
    required this.spotId,
    required this.postType,
    required this.visibility,
    required this.body,
    required this.media,
    required this.meetupDate,
    required this.createdAt,
  });

  final String id;
  final String userId;
  final String authorName;
  final String? authorHandle;
  final String? authorAvatarUrl;
  final bool authorPremium;
  final String? spotId;
  final String postType;
  final String visibility;
  final String body;
  final List<SocialMediaAttachmentModel> media;
  final String? meetupDate;
  final String createdAt;

  factory SocialPostModel.fromJson(
    Map<String, dynamic> json,
  ) => SocialPostModel(
    id: json['id'] as String,
    userId: json['user_id'] as String,
    authorName: json['author_name'] as String,
    authorHandle: json['author_handle'] as String?,
    authorAvatarUrl: json['author_avatar_url'] as String?,
    authorPremium: json['author_premium'] as bool? ?? false,
    spotId: json['spot_id'] as String?,
    postType: json['post_type'] as String,
    visibility: json['visibility'] as String? ?? 'public',
    body: json['body'] as String,
    media: (json['media'] as List<dynamic>? ?? const [])
        .map(
          (item) =>
              SocialMediaAttachmentModel.fromJson(item as Map<String, dynamic>),
        )
        .toList(),
    meetupDate: json['meetup_date'] as String?,
    createdAt: json['created_at'] as String,
  );
}

class SocialMediaAttachmentModel {
  SocialMediaAttachmentModel({
    required this.id,
    required this.mediaType,
    required this.url,
    required this.thumbnailUrl,
    required this.width,
    required this.height,
    required this.altText,
  });

  final String id;
  final String mediaType;
  final String url;
  final String thumbnailUrl;
  final int? width;
  final int? height;
  final String? altText;

  Map<String, dynamic> toJson() => {
    'id': id,
    'media_type': mediaType,
    'url': url,
    'thumbnail_url': thumbnailUrl,
    'width': width,
    'height': height,
    'alt_text': altText,
  };

  factory SocialMediaAttachmentModel.fromJson(Map<String, dynamic> json) =>
      SocialMediaAttachmentModel(
        id: json['id'] as String,
        mediaType: json['media_type'] as String? ?? 'photo',
        url: json['url'] as String,
        thumbnailUrl: json['thumbnail_url'] as String,
        width: json['width'] as int?,
        height: json['height'] as int?,
        altText: json['alt_text'] as String?,
      );
}

class BillingPlanModel {
  BillingPlanModel({
    required this.id,
    required this.name,
    required this.priceUsdMonthly,
    required this.features,
  });

  final String id;
  final String name;
  final double priceUsdMonthly;
  final List<String> features;

  factory BillingPlanModel.fromJson(Map<String, dynamic> json) =>
      BillingPlanModel(
        id: json['id'] as String,
        name: json['name'] as String,
        priceUsdMonthly: (json['price_usd_monthly'] as num).toDouble(),
        features: List<String>.from(json['features'] as List<dynamic>),
      );
}

class AdModel {
  AdModel({
    required this.id,
    required this.title,
    required this.partner,
    required this.cta,
    required this.imageUrl,
    required this.placement,
  });

  final String id;
  final String title;
  final String partner;
  final String cta;
  final String imageUrl;
  final String placement;

  factory AdModel.fromJson(Map<String, dynamic> json) => AdModel(
    id: json['id'] as String,
    title: json['title'] as String,
    partner: json['partner'] as String,
    cta: json['cta'] as String,
    imageUrl: json['image_url'] as String,
    placement: json['placement'] as String,
  );
}

class DashboardModel {
  DashboardModel({
    required this.featuredSpot,
    required this.topForecast,
    required this.upcomingTrip,
    required this.alertsEnabled,
  });

  final SpotModel featuredSpot;
  final ForecastModel topForecast;
  final TripModel? upcomingTrip;
  final int alertsEnabled;

  factory DashboardModel.fromJson(Map<String, dynamic> json) => DashboardModel(
    featuredSpot: SpotModel.fromJson(
      json['featured_spot'] as Map<String, dynamic>,
    ),
    topForecast: ForecastModel.fromJson(
      json['top_forecast'] as Map<String, dynamic>,
    ),
    upcomingTrip: json['upcoming_trip'] == null
        ? null
        : TripModel.fromJson(json['upcoming_trip'] as Map<String, dynamic>),
    alertsEnabled: json['alerts_enabled'] as int? ?? 0,
  );
}
