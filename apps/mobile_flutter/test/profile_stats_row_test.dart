import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_flutter/features/social/social_profile.dart';

void main() {
  testWidgets('profile stats stay on one line at phone width', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 180,
              child: ProfileStatsRow(
                children: [
                  _TestStat(value: '2', label: 'Posts'),
                  _TestStat(value: '2', label: 'Following'),
                  _TestStat(value: '13', label: 'Followers'),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    final postsY = tester.getCenter(find.text('Posts')).dy;
    final followingY = tester.getCenter(find.text('Following')).dy;
    final followersY = tester.getCenter(find.text('Followers')).dy;

    expect(followingY, postsY);
    expect(followersY, postsY);
    expect(tester.takeException(), isNull);
  });
}

class _TestStat extends StatelessWidget {
  const _TestStat({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [Text(value), Text(label)],
    );
  }
}
