class PublicSpotPreview {
  PublicSpotPreview.fromJson(Map<String, dynamic> data)
    : id = data['id'] as String,
      name = data['name'] as String,
      country = data['country'] as String,
      region = data['region'] as String,
      area = data['area'] as String,
      summary = data['summary'] as String,
      difficulty = data['difficulty'] as String,
      bestMonths = List<String>.from(data['best_months'] as List);
  final String id, name, country, region, area, summary, difficulty;
  final List<String> bestMonths;
}

class PublicEventPreview {
  PublicEventPreview.fromJson(Map<String, dynamic> data)
    : id = data['id'] as String,
      body = data['body'] as String,
      meetupDate = data['meetup_date'] as String?,
      meetupEndDate = data['meetup_end_date'] as String?,
      ended = data['ended'] as bool,
      hostName = (data['host'] as Map)['name'] as String,
      hostHandle = (data['host'] as Map)['handle'] as String?,
      hostAvatarUrl = (data['host'] as Map)['avatar_url'] as String?,
      spot = data['spot'] == null
          ? null
          : PublicSpotPreview.fromJson(
              Map<String, dynamic>.from(data['spot'] as Map),
            );
  final String id, body, hostName;
  final String? meetupDate, meetupEndDate, hostHandle, hostAvatarUrl;
  final bool ended;
  final PublicSpotPreview? spot;
}
