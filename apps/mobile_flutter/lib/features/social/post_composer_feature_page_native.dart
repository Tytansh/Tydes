import 'package:flutter/widgets.dart';

import '../../core/network/api_models.dart';
import 'post_composer_module.dart';

class PostComposerFeaturePage extends StatelessWidget {
  const PostComposerFeaturePage({super.key, required this.spots});

  final List<SpotModel> spots;

  @override
  Widget build(BuildContext context) => buildPostComposer(spots: spots);
}
