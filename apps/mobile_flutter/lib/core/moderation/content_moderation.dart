const contentBlockedMessage =
    'This text breaks Tydes community rules. Please edit it and try again.';

final _blockedTextPatterns = <RegExp>[
  RegExp(
    r'\bn[\W_]*[i1!][\W_]*g[\W_]*g[\W_]*(?:e[\W_]*r|a)\b',
    caseSensitive: false,
  ),
  RegExp(
    r'\bf[\W_]*a[\W_]*g[\W_]*(?:g[\W_]*o[\W_]*t|s?)\b',
    caseSensitive: false,
  ),
  RegExp(
    r'\b(?:porn|porno|onlyfans|xxx|hardcore|camgirl|nudes?|nsfw|'
    r'blowjob|handjob|cumshot|sex[\W_]*tape|incest)\b',
    caseSensitive: false,
  ),
  RegExp(r'\b(?:kys|kill[\W_]*yourself)\b', caseSensitive: false),
];

bool hasBlockedContent(String? text) {
  final normalized = text?.trim();
  if (normalized == null || normalized.isEmpty) return false;
  return _blockedTextPatterns.any((pattern) => pattern.hasMatch(normalized));
}

void ensureAllowedContent(Iterable<String?> values) {
  if (values.any(hasBlockedContent)) {
    throw StateError(contentBlockedMessage);
  }
}
